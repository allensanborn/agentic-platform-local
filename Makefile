AGENT := modules/200-agent/customer-agent
ORDERS_DB := $(CURDIR)/data/orders.db
export MODEL_BASE_URL ?= http://localhost:11434/v1
export MODEL_ID       ?= qwen3:8b
export MODEL_API_KEY  ?= not-needed
export ORDERS_DB

.PHONY: seed model venv agent serve cluster gateway clean

seed:            ## build data/orders.db from the workshop's 500-order dataset
	python3 scripts/seed-orders.py

model:           ## pull BOTH local models (local-smart + local-fast, ~6.5GB total)
	ollama pull qwen3:8b
	ollama pull llama3.2:1b

venv:            ## create the agent virtualenv
	cd $(AGENT) && uv venv --python 3.12 .venv && \
	  . .venv/bin/activate && uv pip install -q -r requirements.txt

agent: seed      ## one-shot CLI run against the model
	cd $(AGENT) && . .venv/bin/activate && python agent.py "My order ID is ORD-1001. Where is it?"

serve: seed      ## FastAPI + SSE on :8081
	cd $(AGENT) && . .venv/bin/activate && PORT=8081 python server.py

cluster:         ## k3d cluster + Envoy Gateway + Envoy AI Gateway (lab 0)
	# --disable=traefik: nothing here uses it. k3s ships Traefik by default, which costs 3
	# pods and — worse — installs its own older Gateway API CRDs alongside Envoy Gateway's,
	# leaving two versions of the same API group in one cluster. Zero Ingress objects and no
	# Traefik GatewayClass exist in this stack, so it is pure dead weight.
	k3d cluster create agentic --agents 1 --wait \
	  --k3s-arg "--disable=traefik@server:*" || true
	# The extensionManager block in this values file is REQUIRED and is the whole ballgame:
	# the AI Gateway controller runs as an Envoy Gateway xDS extension server, and that is
	# how the ext_proc filter gets injected. Without it every request returns
	# "No matching route found" even though every CRD reports Accepted=True. See ADR 0002.
	# Gateway API v1.5.0 CRDs FIRST. Envoy Gateway v1.8.x watches ListenerSet at
	# gateway.networking.k8s.io/v1, which only exists in the 1.5.0 bundle; without it the
	# controller crashloops on `no matches for kind "ListenerSet"`.
	kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.0/standard-install.yaml
	# Envoy Gateway v1.8.1 is AI Gateway v1.0.0's documented MINIMUM (site _vars.json:
	# egMinVersion 1.8.1). This repo previously ran v1.5.6, which was never a supported
	# pairing — and is why BackendTLSPolicy was silently ignored (it watched v1alpha3 while
	# the cluster served v1), forcing a cleartext TLS-origination sidecar.
	curl -fsSL -o /tmp/eg-values.yaml https://raw.githubusercontent.com/envoyproxy/ai-gateway/main/manifests/envoy-gateway-values.yaml
	helm upgrade -i eg oci://docker.io/envoyproxy/gateway-helm --version v1.8.1 \
	  -n envoy-gateway-system --create-namespace -f /tmp/eg-values.yaml
	helm upgrade -i aieg-crd oci://docker.io/envoyproxy/ai-gateway-crds-helm --version v1.0.0 \
	  -n envoy-ai-gateway-system --create-namespace --take-ownership
	helm upgrade -i aieg oci://docker.io/envoyproxy/ai-gateway-helm --version v1.0.0 \
	  -n envoy-ai-gateway-system --create-namespace --take-ownership
	kubectl wait --timeout=300s -n envoy-ai-gateway-system deployment/ai-gateway-controller --for=condition=Available
	kubectl apply -f platform/gateway/ai-gateway.yaml

serve-model:     ## Ollama bound to all interfaces so the cluster can reach it
	OLLAMA_HOST=0.0.0.0:11434 ollama serve

gw-forward:      ## port-forward the gateway to :8080
	kubectl port-forward -n envoy-gateway-system \
	  svc/$$(kubectl get svc -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=envoy-ai-gateway -o jsonpath='{.items[0].metadata.name}') 8080:80

agent-via-gateway: seed  ## the lab 0 + 1 payoff: agent -> gateway alias -> Ollama
	cd $(AGENT) && . .venv/bin/activate && \
	  MODEL_BASE_URL=http://localhost:8080/v1 MODEL_ID=local-fast \
	  python agent.py "My order ID is ORD-1003. Where is it?"

gateway:         ## apply the lab-0 gateway manifests (see ADR 0002 — not yet routing)
	kubectl apply -f platform/gateway/ai-gateway.yaml

clean:
	k3d cluster delete agentic || true

# --- architecture diagrams (C4 via Structurizr, Tier 1 headless Docker) -------------
DIAG := docs/architecture

diagrams:        ## validate workspace.dsl and render PNG/SVG + Mermaid into docs/architecture/exports
	docker run --rm -v "$(CURDIR)/$(DIAG):/work" -w /work structurizr/structurizr \
	  export -workspace workspace.dsl -format mermaid -output exports
	docker run --rm -v "$(CURDIR)/$(DIAG):/work" -w /work structurizr/structurizr \
	  export -workspace workspace.dsl -format plantuml -output exports
	cd $(DIAG)/exports && docker run --rm -v "$$PWD:/data" -w /data plantuml/plantuml -tpng "structurizr-*.puml"
	@echo "rendered:"; for f in $(DIAG)/exports/*.png; do printf "  %8s  %s\n" "$$(wc -c < $$f)" "$$f"; done

diagrams-lint:   ## structurizr model lint
	docker run --rm -v "$(CURDIR)/$(DIAG):/work" -w /work structurizr/structurizr \
	  inspect -workspace workspace.dsl

# --- one-command bring-up ------------------------------------------------------------
IMAGES := customer-agent chat-ui mcp-server

images:          ## build the three app images and side-load them into k3d
	docker build -q -t customer-agent:local modules/200-agent/customer-agent
	docker build -q -t chat-ui:local modules/300-ui/chat-ui
	docker build -q -t mcp-server:local modules/500-mcp/mcp-server
	k3d image import customer-agent:local chat-ui:local mcp-server:local -c agentic

# agentgateway install. CRDs FIRST — installing the control plane before its CRDs makes it
# crashloop on `Unauthorized`, because its ClusterRole is generated against types that do not
# exist yet. Also: do NOT name a Gateway `agentgateway` in this namespace; the chart owns a
# Deployment by that name and the controller creates its data plane named after the Gateway,
# so the collision is an immutable-selector error that retries forever behind a green
# Programmed=True. Ours is `mcp-gateway`.
agentgateway:    ## install agentgateway (CRDs then control plane) — lab 3
	helm upgrade -i agentgateway-crds oci://ghcr.io/agentgateway/charts/agentgateway-crds \
	  -n agentgateway-system --create-namespace
	helm upgrade -i agentgateway oci://ghcr.io/agentgateway/charts/agentgateway \
	  -n agentgateway-system
	kubectl rollout status -n agentgateway-system deploy/agentgateway --timeout=300s

deploy:          ## apply the app manifests (labs 1, 3, 4)
	kubectl apply -f modules/200-agent/customer-agent/k8s.yaml
	kubectl apply -f modules/300-ui/chat-ui/k8s.yaml
	kubectl apply -f modules/500-mcp/mcp-server/k8s.yaml
	kubectl rollout status deploy/mcp-server --timeout=180s
	# Lab 4 authz. Applied here rather than in a separate target because without it the
	# gateway is authn-only and every persona sees every tool — the lab-4 property is the
	# DEFAULT state of this repo, not an optional extra.
	kubectl apply -f modules/700-authz/policies/step3-differentiate.yaml
	kubectl rollout status deploy/customer-agent --timeout=180s
	kubectl rollout status deploy/chat-ui --timeout=180s

identity:        ## Keycloak + the anycompany realm (two personas: sam, ana)
	kubectl create namespace identity --dry-run=client -o yaml | kubectl apply -f -
	kubectl create configmap keycloak-realm -n identity \
	  --from-file=realm-anycompany.json=platform/identity/realm-anycompany.json \
	  --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -f platform/identity/keycloak.yaml
	kubectl rollout status -n identity deploy/keycloak --timeout=400s

observability:   ## OTel collector + Langfuse (~1.6 GiB; see ADR 0008)
	kubectl apply -f platform/observability/langfuse/
	kubectl apply -f platform/observability/otel-collector.yaml
	kubectl apply -f platform/observability/gateway-trace-refgrant.yaml
	kubectl rollout status -n langfuse deploy/langfuse-web --timeout=600s
	kubectl rollout status -n telemetry deploy/otel-collector --timeout=180s

# Full cold start, in dependency order. The ORDER is not cosmetic:
#   - Gateway API CRDs must exist before Envoy Gateway (it watches ListenerSet at v1)
#   - CRD charts before control planes (agentgateway crashloops on Unauthorized otherwise)
#   - gvisor before ANY sandbox pod schedules; it restarts the k3d agent node
#   - gitea before coding-deploy (the dispatcher needs the coding-agent-creds Secret)
# On an ALREADY-RUNNING cluster prefer the sub-targets: `make gvisor` restarts a node and is
# disruptive mid-session.
up-all: cluster gvisor agentgateway sandbox-platform observability identity gitea images deploy \
        sandbox-images sandbox-deploy coding-images coding-platform coding-deploy
	@echo ""
	@echo "Cold start complete. Remaining manual steps:"
	@echo "  make model            # ollama pull qwen3:8b llama3.2:1b (~6.5GB, one time)"
	@echo "  make serve-model      # Ollama bound to 0.0.0.0 so the cluster can reach it"
	@echo "  make model-key        # only if using OpenRouter (see scripts/set-model-key.sh)"
	@echo "  make model-remote     # adds the remote-* aliases"
	@echo "  make ui               # then open http://127.0.0.1:8000"

up: cluster images deploy  ## labs 0-1 only. For everything, use `make up-all`
	@echo ""
	@echo "Ready. Start the model and open the UI:"
	@echo "  make serve-model     # in another shell, if ollama isn't already running"
	@echo "  make ui              # then open http://127.0.0.1:8000"

ui:              ## port-forward the chat UI to :8000
	kubectl port-forward svc/chat-ui 8000:8000

down:            ## delete the cluster
	k3d cluster delete agentic

# --- lab 5: sandbox runtime -----------------------------------------------------------
gvisor:          ## install gVisor (runsc) into the k3d node + register the RuntimeClass
	./scripts/install-gvisor.sh

sandbox-verify:  ## prove the sandbox has its own kernel (the workshop's own check)
	@kubectl delete pod gvisor-smoke --ignore-not-found >/dev/null 2>&1 || true
	@kubectl run gvisor-smoke --image=busybox:1.36 --restart=Never \
	  --overrides='{"spec":{"runtimeClassName":"gvisor"}}' --command -- sh -c 'uname -r' >/dev/null
	@sleep 12
	@echo "node kernel:    $$(docker exec k3d-agentic-agent-0 uname -r)"
	@echo "sandbox kernel: $$(kubectl logs gvisor-smoke 2>/dev/null)"
	@kubectl delete pod gvisor-smoke --ignore-not-found >/dev/null 2>&1 || true

# --- lab 5: sandboxed code execution --------------------------------------------------
SANDBOX := modules/900-sandbox
BROKER  := $(SANDBOX)/code-executor-mcp

sandbox-platform: ## install upstream agent-sandbox v0.5.0 + the gVisor template/warmpool
	./scripts/install-agent-sandbox.sh

sandbox-images:  ## build + side-load the sandbox runtime and the broker
	docker build -q -t python-runtime-sandbox:local $(SANDBOX)/python-runtime-sandbox
	docker build -q -t code-executor-mcp:local $(BROKER)
	k3d image import python-runtime-sandbox:local code-executor-mcp:local -c agentic
	# The warm pool holds pods pinned to the OLD image id; imagePullPolicy: Never means a
	# rebuild is invisible until the pool is recycled. Delete and let the controller refill.
	kubectl delete pod -n agent-sandbox --all --ignore-not-found >/dev/null 2>&1 || true

sandbox-deploy:  ## broker + gateway route + the sales-analyst authz policy
	kubectl apply -f $(BROKER)/k8s.yaml
	kubectl apply -f $(SANDBOX)/policies/run-python-authz.yaml
	kubectl apply -f modules/200-agent/customer-agent/k8s.yaml
	kubectl rollout status deploy/code-executor-mcp --timeout=240s
	kubectl rollout restart deploy/customer-agent
	kubectl rollout status deploy/customer-agent --timeout=240s

sandbox: gvisor sandbox-platform sandbox-images sandbox-deploy  ## lab 5, end to end
	@echo ""
	@echo "Lab 5 up. Verify:  make sandbox-test"

sandbox-unit:    ## broker unit tests (no cluster needed)
	cd $(BROKER) && { test -d .venv || uv venv --python 3.12 .venv -q; } && \
	  . .venv/bin/activate && \
	  uv pip install -q -r requirements.txt pytest && python -m pytest -q

sandbox-forward: ## port-forwards the probes need, all in one shell (blocks)
	@echo "broker :8090   gateway :8081   keycloak :8085   agent :8082"
	@kubectl port-forward svc/code-executor-mcp 8090:8080 & \
	 kubectl port-forward -n agentgateway-system svc/mcp-gateway 8081:80 & \
	 kubectl port-forward -n identity svc/keycloak 8085:8080 & \
	 kubectl port-forward svc/customer-agent 8082:8080 & \
	 wait

PROBE = cd $(SANDBOX) && . code-executor-mcp/.venv/bin/activate && python probe.py

sandbox-test:    ## the model-free control: drive run_python over MCP (needs sandbox-forward)
	@echo "=== broker directly, no gateway ==="
	@$(PROBE) --url http://127.0.0.1:8090/mcp
	@echo ""
	@echo "=== ana (sales-analyst) through agentgateway ==="
	@$(PROBE) --url http://127.0.0.1:8081/code-mcp --user ana --tools-only
	@echo "=== sam (support-associate) through agentgateway — run_python must be invisible ==="
	@$(PROBE) --url http://127.0.0.1:8081/code-mcp --user sam --tools-only

sandbox-airgap:  ## run hostile code IN a claimed sandbox and show the air-gap holding
	@echo "=== inside a CLAIMED sandbox (not a pooled one — see ADR 0006) ==="
	@$(PROBE) --url http://127.0.0.1:8090/mcp --escape
	@echo ""
	@echo "=== CONTROL: same probe from a pod the policy does NOT select ==="
	@echo "    (a 'blocked' above proves nothing unless this one connects)"
	@kubectl delete pod -n agent-sandbox airgap-control --ignore-not-found >/dev/null 2>&1 || true
	@kubectl run airgap-control -n agent-sandbox --image=python-runtime-sandbox:local \
	  --restart=Never --overrides='{"spec":{"runtimeClassName":"gvisor","containers":[{"name":"c","image":"python-runtime-sandbox:local","imagePullPolicy":"Never","command":["sleep","300"]}]}}' >/dev/null
	@kubectl wait --for=condition=Ready pod/airgap-control -n agent-sandbox --timeout=120s >/dev/null
	@kubectl exec -n agent-sandbox airgap-control -- python3 -c "\
import socket; s=socket.socket(); s.settimeout(5); s.connect(('1.1.1.1',443)); \
print('CONTROL connected to 1.1.1.1:443 — the policy, not the runtime, is what blocks the sandbox')"
	@kubectl delete pod -n agent-sandbox airgap-control --wait=false >/dev/null 2>&1 || true

sandbox-pool:    ## show the warm pool, any live claim, and the labels that drive the policy
	kubectl get sandboxtemplate,sandboxwarmpool,sandboxclaim -n agent-sandbox
	kubectl get pod -n agent-sandbox --show-labels
	kubectl get networkpolicy -n agent-sandbox

sandbox-lifecycle: ## hold a sandbox open 40s and show claim -> run -> destroy -> refill
	@$(PROBE) --url http://127.0.0.1:8090/mcp --sleep 40 >/tmp/sandbox-lifecycle.log 2>&1 & \
	 sleep 15; echo "=== DURING ==="; kubectl get sandboxclaim -n agent-sandbox; \
	 kubectl get pod -n agent-sandbox --show-labels; \
	 sleep 45; echo ""; echo "=== AFTER ==="; kubectl get sandboxclaim -n agent-sandbox; \
	 kubectl get pod -n agent-sandbox --show-labels; tail -6 /tmp/sandbox-lifecycle.log

sandbox-ask:     ## end-to-end through the model: make sandbox-ask USER=ana Q="..."
	@$(SANDBOX)/ask.sh $(or $(USER_NAME),ana) "$(or $(Q),What were total 2026-Q1 sales aggregated by region?)"

# --- labs 6-7: autonomous coding agent -------------------------------------------------
CODING := modules/1000-coding-agent

gitea:           ## deploy Gitea + provision bot/repo/label/webhook (idempotent)
	kubectl apply -f platform/gitea/gitea.yaml
	./platform/gitea/provision.sh

gitea-ui:        ## port-forward Gitea to :3001 (login printed by `make gitea`)
	kubectl port-forward -n gitea svc/gitea-http 3001:3000

coding-images:   ## build + side-load the coding runtime and the dispatcher
	docker build -q -t coding-runtime-sandbox:local $(CODING)/coding-runtime-sandbox
	docker build -q -t coding-agent-dispatcher:local $(CODING)/coding-agent-dispatcher
	k3d image import coding-runtime-sandbox:local coding-agent-dispatcher:local -c agentic
	# Warm-pool pods are pinned to the OLD image id and imagePullPolicy: Never means a
	# rebuild is invisible until the pool is recycled. Same trap as lab 5.
	kubectl delete pod -n agent-sandbox -l sandbox-kind=coding --ignore-not-found >/dev/null 2>&1 || true

coding-platform: ## coding sandbox template + warm pool + the egress lock + gateway buffer
	kubectl apply -f platform/gateway/client-traffic-policy-buffer.yaml
	kubectl apply -f platform/sandbox/sandboxtemplate-gvisor-coding.yaml
	kubectl apply -f platform/sandbox/sandboxwarmpool-gvisor-coding.yaml
	kubectl apply -f platform/sandbox/sandbox-coding-egress-networkpolicy.yaml
	kubectl apply -f platform/sandbox/router-ingress-networkpolicy.yaml

coding-deploy:   ## the dispatcher (needs `make gitea` first for coding-agent-creds)
	kubectl apply -f $(CODING)/coding-agent-dispatcher/k8s.yaml
	kubectl rollout status deploy/coding-agent-dispatcher --timeout=240s

coding: gitea coding-platform coding-images coding-deploy  ## labs 6-7, end to end
	@echo ""
	@echo "Labs 6-7 up. Trigger a run:"
	@echo "  make coding-issue TITLE=\"Add a /health endpoint\" BODY=\"Return {\\\"status\\\": \\\"ok\\\"}.\""

coding-unit:     ## dispatcher unit tests (no cluster needed)
	cd $(CODING)/coding-agent-dispatcher && { test -d .venv || uv venv --python 3.12 .venv -q; } && \
	  . .venv/bin/activate && uv pip install -q fastapi httpx pytest && python -m pytest -q

coding-issue:    ## file + label an issue: make coding-issue TITLE="..." BODY="..."
	@$(CODING)/issue.sh "$(or $(TITLE),Add a /health endpoint)" "$(or $(BODY),Add a GET /health endpoint to app.py returning {\"status\": \"ok\"}. Add a test.)"

coding-show:     ## issue comments + PRs: make coding-show N=1
	@$(CODING)/show.sh $(or $(N),1)

coding-egress-check: ## THE control: probe from a CLAIMED sandbox + a pod the policy misses
	@$(CODING)/verify-egress.sh

coding-token-check:  ## mint -> authenticates -> revoke -> 401, plus a residue check
	@$(CODING)/verify-token.sh $(TOKEN)

coding-watch:    ## follow the dispatcher and the claimed sandbox
	@kubectl logs -f deploy/coding-agent-dispatcher | grep -v healthz & \
	 kubectl logs -f -n agent-sandbox -l sandbox-kind=coding --max-log-requests=4 & \
	 wait

# --- modules 600 + 800: multi-agent A2A -------------------------------------------------
# The workshop's third hop: agent -> agent. Additive — it reuses the mcp-gateway, Keycloak and
# the MCP server that are already running, and installs no new infrastructure.
A2A      := modules/600-a2a
A2AAGENT := $(A2A)/a2a-agents

a2a-images:      ## build + side-load the orchestrator and both specialists
	docker build -q -t orchestrator-agent:local -f $(A2AAGENT)/Dockerfile.orchestrator $(A2AAGENT)
	docker build -q -t order-agent:local        -f $(A2AAGENT)/Dockerfile.order        $(A2AAGENT)
	docker build -q -t product-agent:local      -f $(A2AAGENT)/Dockerfile.product      $(A2AAGENT)
	k3d image import orchestrator-agent:local order-agent:local product-agent:local -c agentic
	# imagePullPolicy: Never pins a running pod to the OLD image id, so a rebuild is invisible
	# until something restarts it. Same trap as the sandbox warm pools above.
	kubectl rollout restart deploy/orchestrator-agent deploy/order-agent deploy/product-agent 2>/dev/null || true

a2a-deploy:      ## specialists + the A2A routes + the orchestrator
	kubectl apply -f $(A2AAGENT)/k8s-specialists.yaml
	kubectl apply -f $(A2AAGENT)/k8s-orchestrator.yaml
	kubectl rollout status deploy/order-agent --timeout=240s
	kubectl rollout status deploy/product-agent --timeout=240s
	kubectl rollout status deploy/orchestrator-agent --timeout=240s

a2a-authz:       ## module 800 — the authn gate on both A2A routes
	kubectl apply -f modules/800-a2a-authz/policies/a2a-authn.yaml

a2a: a2a-images a2a-deploy a2a-authz  ## modules 600+800, end to end
	@echo ""
	@echo "A2A up. In another shell: make a2a-forward"
	@echo "  make a2a-verify   # the authorization matrix (model-free)"
	@echo "  make a2a-hops     # persona propagation across BOTH hops (model-free)"
	@echo "  make a2a-ask USER_NAME=sam Q=\"Where is order ORD-1001?\""

a2a-forward:     ## port-forwards the A2A probes need, all in one shell (blocks)
	@echo "gateway :8081   keycloak :8085   orchestrator :8083   order-agent DIRECT :8181"
	@kubectl port-forward -n agentgateway-system svc/mcp-gateway 8081:80 & \
	 kubectl port-forward -n identity svc/keycloak 8085:8080 & \
	 kubectl port-forward svc/orchestrator-agent 8083:8083 & \
	 kubectl port-forward svc/order-agent 8181:8081 & \
	 wait

a2a-verify:      ## the authorization matrix at the A2A hop, and the CRD reason for its shape
	@$(A2A)/verify.sh

a2a-hops:        ## persona propagation across both hops, proven by the discovered tool list
	@$(A2A)/hops.sh

a2a-bypass:      ## a gate is only a gate if it is the only path: hit the Service directly
	@echo "=== through agentgateway, no token (expect 401) ==="
	@python3 $(A2A)/a2a-probe.py --agent order --card || true
	@echo ""
	@echo "=== straight at the order-agent Service, no token (expect 200) ==="
	@python3 $(A2A)/a2a-probe.py --url http://127.0.0.1:8181 --card || true

a2a-ask:         ## end-to-end through the model: make a2a-ask USER_NAME=sam Q="..."
	@$(A2A)/ask.sh $(or $(USER_NAME),sam) "$(or $(Q),Where is my order ORD-1001?)"

a2a-logs:        ## follow all three agents
	@kubectl logs -f deploy/orchestrator-agent | grep -v healthz & \
	 kubectl logs -f deploy/order-agent & \
	 kubectl logs -f deploy/product-agent & \
	 wait

# --- optional: a hosted model behind the same alias table -------------------------------
model-key:       ## load the OpenRouter key into the cluster (see scripts/set-model-key.sh)
	./scripts/set-model-key.sh
	./scripts/model-key-gateway.sh

model-remote:    ## add the OpenRouter backend + `remote-*` aliases to the gateway
	kubectl apply -f platform/gateway/openrouter.yaml

model-remote-test: ## one Anthropic-format call per remote alias, through the gateway
	@P=$$(kubectl get pod -n gitea -l app.kubernetes.io/name=gitea -o jsonpath='{.items[0].metadata.name}'); \
	for m in remote-smart remote-fast; do \
	  printf '%-14s ' "$$m"; \
	  kubectl exec -n gitea $$P -- curl -sS -X POST \
	    http://ai-gateway.envoy-gateway-system.svc.cluster.local/anthropic/v1/messages \
	    -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' \
	    -H 'x-api-key: not-needed' \
	    -d "{\"model\":\"$$m\",\"max_tokens\":32,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with OK\"}]}" \
	    | head -c 300; echo; \
	done

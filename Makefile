AGENT := modules/200-agent/customer-agent
ORDERS_DB := $(CURDIR)/data/orders.db
export MODEL_BASE_URL ?= http://localhost:11434/v1
export MODEL_ID       ?= qwen3:8b
export MODEL_API_KEY  ?= not-needed
export ORDERS_DB

.PHONY: seed model venv agent serve cluster gateway clean

seed:            ## build data/orders.db from the workshop's 500-order dataset
	python3 scripts/seed-orders.py

model:           ## pull the local model
	ollama pull $(MODEL_ID)

venv:            ## create the agent virtualenv
	cd $(AGENT) && uv venv --python 3.12 .venv && \
	  . .venv/bin/activate && uv pip install -q -r requirements.txt

agent: seed      ## one-shot CLI run against the model
	cd $(AGENT) && . .venv/bin/activate && python agent.py "My order ID is ORD-1001. Where is it?"

serve: seed      ## FastAPI + SSE on :8081
	cd $(AGENT) && . .venv/bin/activate && PORT=8081 python server.py

cluster:         ## k3d cluster + Envoy Gateway + Envoy AI Gateway (lab 0)
	k3d cluster create agentic --agents 1 --wait || true
	# The extensionManager block in this values file is REQUIRED and is the whole ballgame:
	# the AI Gateway controller runs as an Envoy Gateway xDS extension server, and that is
	# how the ext_proc filter gets injected. Without it every request returns
	# "No matching route found" even though every CRD reports Accepted=True. See ADR 0002.
	curl -fsSL -o /tmp/eg-values.yaml https://raw.githubusercontent.com/envoyproxy/ai-gateway/main/manifests/envoy-gateway-values.yaml
	helm upgrade -i eg oci://docker.io/envoyproxy/gateway-helm --version v1.5.6 \
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
IMAGES := customer-agent chat-ui

images:          ## build both app images and side-load them into k3d
	docker build -q -t customer-agent:local modules/200-agent/customer-agent
	docker build -q -t chat-ui:local modules/300-ui/chat-ui
	k3d image import customer-agent:local chat-ui:local -c agentic

deploy:          ## apply the app manifests
	kubectl apply -f modules/200-agent/customer-agent/k8s.yaml
	kubectl apply -f modules/300-ui/chat-ui/k8s.yaml
	kubectl rollout status deploy/customer-agent --timeout=180s
	kubectl rollout status deploy/chat-ui --timeout=180s

up: cluster images deploy  ## cluster + gateway + images + deploy, end to end
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

# --- optional: a hosted model behind the same alias table -------------------------------
model-key:       ## load the OpenRouter key into the cluster (see scripts/set-model-key.sh)
	./scripts/set-model-key.sh
	./scripts/model-key-gateway.sh

model-remote:    ## add the OpenRouter backend + `remote-*` aliases to the gateway
	kubectl apply -f platform/gateway/openrouter-tls-proxy.yaml
	kubectl rollout status -n model-access deploy/openrouter-tls-proxy --timeout=180s
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

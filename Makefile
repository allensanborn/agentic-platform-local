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

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

cluster:         ## k3d cluster + Envoy Gateway + Envoy AI Gateway
	k3d cluster create agentic --agents 1 --wait || true
	helm upgrade -i eg oci://docker.io/envoyproxy/gateway-helm --version v1.5.6 \
	  -n envoy-gateway-system --create-namespace \
	  --set config.envoyGateway.extensionApis.enableBackend=true
	helm upgrade -i aieg-crd oci://docker.io/envoyproxy/ai-gateway-crds-helm --version v1.0.0 \
	  -n envoy-ai-gateway-system --create-namespace --take-ownership
	helm upgrade -i aieg oci://docker.io/envoyproxy/ai-gateway-helm --version v1.0.0 \
	  -n envoy-ai-gateway-system --create-namespace --take-ownership
	kubectl wait --timeout=240s -n envoy-ai-gateway-system deployment/ai-gateway-controller --for=condition=Available

gateway:         ## apply the lab-0 gateway manifests (see ADR 0002 — not yet routing)
	kubectl apply -f platform/gateway/ai-gateway.yaml

clean:
	k3d cluster delete agentic || true

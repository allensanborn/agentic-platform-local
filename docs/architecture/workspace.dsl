/*
 * Local rebuild of AWS's "Secure AI Agents on Amazon EKS" workshop.
 *
 * One model, many views. This file grows one lab at a time — the point of the demo is the
 * CONNECTIONS between components, so every lab adds a control point here and the diagram
 * shows what changed.
 *
 * Scoping decisions (state them so they can be argued with):
 *   audience  — Allen, plus anyone reading the repo as a portfolio artifact
 *   purpose   — show where each workshop control point lives once AWS is removed, and which
 *               hop each one governs
 *   scope     — ONE software system (the local agentic platform), single workspace
 *   actors    — the shopper talking to the agent, and the operator running the platform
 *
 * Each container carries a `technology` string naming BOTH the local choice and the AWS
 * component it replaces, so the substitution is legible from the diagram alone.
 */
workspace "Agentic Platform (local)" "AWS Secure-AI-Agents-on-EKS workshop, rebuilt from open source on one machine" {

    model {
        shopper  = person "Shopper" "Asks about their order in natural language."
        operator = person "Platform Operator" "Runs the cluster and owns the control points."

        openrouter = softwareSystem "OpenRouter" "Free-tier frontier-class models. Reached ONLY by the gateway, over direct TLS with certificate verification — there is no cleartext hop and no sandbox ever talks to it." {
            tags "External"
        }

        platform = softwareSystem "Agentic Platform (local)" "Customer-service agent and the infrastructure that governs it." {

            ui = container "Chat UI" "Streams the agent's answer and renders tool calls as steps." "Chainlit (workshop: same)" {
                tags "UI"
            }

            agent = container "Customer Agent" "Agent loop: picks tools, calls the model, streams SSE. agent.py/server.py run VERBATIM from the workshop." "Python, Strands Agents SDK, FastAPI" {
                tags "Agent"
            }

            gateway = container "AI Gateway" "LAB 0 control point. Owns WHICH model answers: agents ask for an alias, the gateway rewrites it to a real model. Also the only thing that would hold a model credential." "Envoy AI Gateway (workshop: same, fronting Bedrock)" {
                tags "ControlPoint"
            }

            ollama = container "Local Model Runtime" "Serves qwen3:8b and llama3.2:1b over an OpenAI-compatible API. Runs on the HOST, not in the cluster, because that is where the GPU is." "Ollama (workshop: Amazon Bedrock)" {
                tags "Model"
            }

            collector = container "OTel Collector" "LAB 2 control point. Every workload speaks plain OTLP here and holds NO credential for the tracing backend — one key to rotate. Also where telemetry is SHAPED: a filter rule drops the per-SSE-chunk spans that took one trace from 543 spans to 9." "OpenTelemetry Collector (workshop: same)" {
                tags "ControlPoint"
            }

            tracing = container "Trace Backend" "Renders the agent trace tree: invoke_agent -> event loop -> chat -> tool, with GenAI semantic-convention attributes, prompt/completion rendering and token cost." "Langfuse (workshop: same). Six containers at ~1.6 GiB — the 16 GiB sizing guidance is a production recommendation, not a floor; see ADR 0008" {
                tags "Observability"
            }

            mcpgw = container "Agent Gateway" "LAB 3/4 control point. Owns WHICH TOOLS an agent can see and call. Because tool calls now cross a network they are interceptable — lab 4 spends that." "agentgateway (workshop: same)" {
                tags "ControlPoint"
            }

            mcp = container "MCP Tool Server" "lookup_order, check_inventory, initiate_return. Ships and scales independently of the agent; discovered at runtime via list_tools." "Python, FastMCP (workshop: same)" {
                tags "Tools"
            }

            idp = container "Identity Provider" "Issues JWTs carrying a `groups` claim. The ENTIRE Cognito coupling this replaces was two strings (issuer, JWKS) and one claim name: cognito:groups -> groups." "Keycloak (workshop: Amazon Cognito)" {
                tags "Identity"
            }

            broker = container "Code-Exec Broker" "LAB 5 control point. The model picks a period/region; the BROKER builds the scoped, parameterized query. Raw rows enter the sandbox as a FILE, never through the LLM context; the chart returns as bytes behind a short chart_id the model cannot dereference." "Python, FastMCP (workshop: same)" {
                tags "ControlPoint"
            }

            sandbox = container "Code Sandbox" "Runs model-written pandas air-gapped and single-use: claim, run, destroy, pool refills. No network, no Kubernetes token. Own kernel — verified the workshop's own way, uname -r returns 4.19.0-gvisor." "gVisor via RuntimeClass + upstream agent-sandbox (workshop: Kata + Firecracker)" {
                tags "Sandbox"
            }

            gitea = container "Git Server" "Holds the repo the coding agent edits. Also the human-in-the-loop boundary: the agent's job ends at a PR." "Gitea (workshop: same)" {
                tags "Tools"
            }

            dispatcher = container "Coding-Agent Dispatcher" "LABS 6-7 control point. Mints a per-run git token and revokes it after; claims a sandbox; and holds the push credential so the MODEL never does — Claude is told to commit, not to push." "Python, FastAPI (workshop: same)" {
                tags "ControlPoint"
            }

            codingsandbox = container "Coding Sandbox" "Runs the real `claude -p` CLI, unpatched. Egress locked to exactly two in-cluster destinations; no standing credential; no service-account token." "gVisor + Claude Code (workshop: Kata/Firecracker + Claude Code)" {
                tags "Sandbox"
            }

            orders = container "Orders Store" "500 seeded orders. Read via a scoped, parameterized query — the agent never writes SQL." "SQLite (workshop: Amazon DynamoDB)" {
                tags "Data"
            }
        }

        # --- relationships: the hops are the lesson -------------------------------------
        shopper  -> ui       "Asks about an order"
        operator -> gateway  "Changes the model alias table (no agent redeploy)"

        ui    -> agent    "POST /chat, consumes SSE" "HTTP/SSE"
        agent -> gateway  "Chat completions, asking for the ALIAS 'local-smart'" "HTTP, OpenAI wire format"
        agent -> mcpgw    "list_tools at session start, then tool calls" "MCP / StreamableHTTP"
        mcpgw -> mcp      "Proxies MCP, and enforces per-tool authorization" "MCP / StreamableHTTP"
        mcpgw -> idp      "Fetches JWKS, validates every token (mode: Strict)" "HTTP"
        shopper -> idp    "Signs in as a persona" "OIDC"
        mcp   -> orders   "Scoped, parameterized read" "SQLite"

        gateway -> ollama    "Rewrites alias -> qwen3:8b, forwards" "HTTP, OpenAI wire format"

        agent     -> collector "Spans, zero tracing code — opentelemetry-instrument patches httpx + FastAPI" "OTLP/HTTP"
        gateway   -> collector "Spans. Needed appProtocol: grpc on the collector Service — without it Envoy speaks gRPC over HTTP/1.1 and the receiver rejects every stream while reporting nothing" "OTLP/gRPC"
        collector -> tracing   "The single authenticated egress" "OTLP/gRPC"
        gateway -> openrouter "Same hop, different backend — a config change, not a code change. Direct TLS, system trust store, via BackendTLSPolicy" "HTTPS"

        agent      -> broker        "run_python(period, region) — gated to the sales-analyst persona" "MCP via the agent gateway"
        broker     -> orders        "Scoped, parameterized query the model never writes" "SQLite"
        broker     -> sandbox       "Uploads rows + generated code as FILES, executes, reads back, destroys" "HTTP, single-use"

        operator   -> gitea         "Labels an issue to trigger the agent"
        gitea      -> dispatcher    "Webhook on the `agent` label" "HTTP"
        dispatcher -> gitea         "Mints a per-run token, pushes the branch, opens the PR, revokes the token" "HTTP"
        dispatcher -> codingsandbox "Claims a sandbox, uploads the task, runs claude -p" "HTTP, single-use"
        codingsandbox -> gateway    "Anthropic Messages format — the gateway translates to OpenAI and holds the key" "HTTPS"
        codingsandbox -> gitea      "Clones and commits. The WRAPPER pushes; the model never holds the credential" "HTTP"

        # --- deployment: where it all actually runs --------------------------------------
        deploymentEnvironment "Laptop" {
            deploymentNode "Developer Laptop (macOS, Apple Silicon, 24 GB)" {
                deploymentNode "Host OS" {
                    deploymentNode "Ollama" "Bound to 0.0.0.0:11434 so the cluster can reach it" {
                        containerInstance ollama
                    }
                }
                deploymentNode "OrbStack Linux VM" "NOT Docker Desktop — assuming so cost a wrong memory ceiling AND a wrong TLS diagnosis. OrbStack allocates dynamically (soft cap memory_mib: 12288). Reached from the cluster as host.docker.internal; host.k3d.internal resolves to THIS VM, not the Mac." {
                    deploymentNode "k3d cluster 'agentic'" "k3s in Docker. Chosen over kind because kindnet silently ignores NetworkPolicy, which lab 5 depends on." {
                        deploymentNode "namespace: envoy-gateway-system" {
                            deploymentNode "Envoy data plane" "Service pinned to the name 'ai-gateway' so MODEL_BASE_URL is stable" {
                                containerInstance gateway
                            }
                        }
                        deploymentNode "namespace: agentgateway-system" "Gateway named mcp-gateway, NOT agentgateway — the Helm chart owns a Deployment of that name and the collision is an immutable-selector error that retries forever behind a green status" {
                            containerInstance mcpgw
                        }
                        deploymentNode "namespace: identity" {
                            containerInstance idp
                        }
                        deploymentNode "namespace: gitea" {
                            containerInstance gitea
                        }
                        deploymentNode "namespace: agent-sandbox" "Warm pools of PRE-CLAIMED gVisor sandboxes. The air-gap NetworkPolicy must select a label that SURVIVES the claim relabel — agents.x-k8s.io/warm-pool-sandbox is removed on claim, so a policy keyed to it protects the sandbox only while it is idle (beads llm-wiki-661.13)." {
                            containerInstance sandbox
                            containerInstance codingsandbox
                        }
                        deploymentNode "namespace: telemetry" {
                            containerInstance collector
                            containerInstance tracing
                        }
                        deploymentNode "namespace: default" {
                            deploymentNode "Deployment: customer-agent" "LAB 3: no orders volume any more — the agent has no path to the store" {
                                containerInstance agent
                            }
                            deploymentNode "Deployment: mcp-server" "initContainer seeds the orders DB here; the data moved to the TOOLS" {
                                containerInstance mcp
                                containerInstance orders
                            }
                            deploymentNode "Deployment: chat-ui" {
                                containerInstance ui
                            }
                            deploymentNode "Deployment: code-executor-mcp" {
                                containerInstance broker
                            }
                            deploymentNode "Deployment: coding-agent-dispatcher" {
                                containerInstance dispatcher
                            }
                        }
                    }
                }
            }
        }
    }

    views {
        systemContext platform "SystemContext" "Who uses the platform, and the one external system it can reach." {
            include *
            autolayout lr
        }

        container platform "Containers" "The hops. Lab 0 puts a control point between the agent and the model; later labs add one per hop." {
            include *
            autolayout lr
        }

        container platform "ControlPoints" "Just the chokepoints and what each one governs. Every lab adds exactly one, and none of them makes the agent smarter or more trusted." {
            include gateway mcpgw collector broker dispatcher agent ollama openrouter idp sandbox codingsandbox
            autolayout lr
        }

        deployment platform "Laptop" "Deployment" "Where each container actually runs — and the two host-boundary gotchas that cost real debugging time." {
            include *
            autolayout lr
        }

        styles {
            element "Person" {
                shape person
                background #08427b
                color #ffffff
            }
            element "Software System" {
                background #1168bd
                color #ffffff
            }
            element "Container" {
                background #438dd5
                color #ffffff
            }
            element "ControlPoint" {
                background #b8860b
                color #ffffff
                shape hexagon
            }
            element "Model" {
                background #6b4fa0
                color #ffffff
            }
            element "Data" {
                shape cylinder
                background #2e7d32
                color #ffffff
            }
            element "UI" {
                shape webBrowser
                background #438dd5
                color #ffffff
            }
            element "Agent" {
                background #c0392b
                color #ffffff
            }
            element "Identity" {
                background #ad1457
                color #ffffff
            }
            element "Sandbox" {
                background #4e342e
                color #ffffff
                shape hexagon
            }
            element "Tools" {
                background #1565c0
                color #ffffff
            }
            element "Observability" {
                background #00695c
                color #ffffff
            }
            element "External" {
                background #999999
                color #ffffff
            }
            element "Optional" {
                opacity 60
            }
            relationship "Optional" {
                style dashed
                opacity 60
            }
        }
    }
}

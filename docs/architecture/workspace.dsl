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

        anthropic = softwareSystem "Anthropic API" "Frontier model, used only where a local model is not good enough (labs 6-7)." {
            tags "External" "Optional"
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

            tracing = container "Trace Backend" "Renders the agent trace tree: invoke_agent -> event loop -> chat -> tool, with GenAI semantic-convention attributes." "Jaeger (workshop: Langfuse — six containers, would not fit here; see ADR 0004)" {
                tags "Observability"
            }

            mcpgw = container "Agent Gateway" "LAB 3/4 control point. Owns WHICH TOOLS an agent can see and call. Because tool calls now cross a network they are interceptable — lab 4 spends that." "agentgateway (workshop: same)" {
                tags "ControlPoint"
            }

            mcp = container "MCP Tool Server" "lookup_order, check_inventory, initiate_return. Ships and scales independently of the agent; discovered at runtime via list_tools." "Python, FastMCP (workshop: same)" {
                tags "Tools"
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
        mcpgw -> mcp      "Proxies MCP; enforces policy in lab 4" "MCP / StreamableHTTP"
        mcp   -> orders   "Scoped, parameterized read" "SQLite"

        gateway -> ollama    "Rewrites alias -> qwen3:8b, forwards" "HTTP, OpenAI wire format"

        agent     -> collector "Spans, zero tracing code — opentelemetry-instrument patches httpx + FastAPI" "OTLP/HTTP"
        gateway   -> collector "Spans (configured; not yet landing — see ADR 0004)" "OTLP/gRPC" {
            tags "Broken"
        }
        collector -> tracing   "The single authenticated egress" "OTLP/gRPC"
        gateway -> anthropic "Same hop, different backend — a config change, not a code change" "HTTPS, Anthropic wire format" {
            tags "Optional"
        }

        # --- deployment: where it all actually runs --------------------------------------
        deploymentEnvironment "Laptop" {
            deploymentNode "Developer Laptop (macOS, Apple Silicon)" {
                deploymentNode "Host OS" {
                    deploymentNode "Ollama" "Bound to 0.0.0.0:11434 so the cluster can reach it" {
                        containerInstance ollama
                    }
                }
                deploymentNode "Docker Desktop VM" "Reached from the cluster as host.docker.internal — NOT host.k3d.internal, which resolves to this VM rather than the Mac" {
                    deploymentNode "k3d cluster 'agentic'" "k3s in Docker. Chosen over kind because kindnet silently ignores NetworkPolicy, which lab 5 depends on." {
                        deploymentNode "namespace: envoy-gateway-system" {
                            deploymentNode "Envoy data plane" "Service pinned to the name 'ai-gateway' so MODEL_BASE_URL is stable" {
                                containerInstance gateway
                            }
                        }
                        deploymentNode "namespace: agentgateway-system" "Gateway named mcp-gateway, NOT agentgateway — the Helm chart owns a Deployment of that name and the collision is an immutable-selector error that retries forever behind a green status" {
                            containerInstance mcpgw
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
            relationship "Broken" {
                style dotted
                color #b00020
            }
            relationship "Optional" {
                style dashed
                opacity 60
            }
        }
    }
}

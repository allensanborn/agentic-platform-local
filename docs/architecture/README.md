# Architecture diagrams

C4 model as **Structurizr DSL** — one text model (`workspace.dsl`), many views, no drift between them.
Rendered locally with Docker; nothing is uploaded anywhere.

```bash
make diagrams        # validate + render Mermaid, PlantUML, PNG
make diagrams-lint   # model lint
```

## Views

| View | What it answers |
|---|---|
| `SystemContext` | Who uses the platform, and the one external system it can reach |
| `Containers` | **The hops.** Each lab adds a control point on one of them |
| `ControlPoints` | **Start here.** Just the chokepoints and what each governs — every lab adds exactly one |
| `Deployment` | Where each container actually runs on one laptop, namespace by namespace |

## Why the deployment view earns its place

It makes the boundary that cost the most debugging time visible: **Ollama runs on the Host OS,
outside the Docker Desktop VM**, so the cluster reaches it as `host.docker.internal` and not
`host.k3d.internal` (which resolves to the VM itself). That is a sentence in an ADR and a
picture in the diagram, and the picture is faster.

## Convention

Every container's `technology` string names **both** the local choice and the AWS component it
replaces — `SQLite (workshop: Amazon DynamoDB)` — so the substitution table is readable off the
diagram without cross-referencing the README.

The model grows one lab at a time. A lab that adds a control point adds it here in the same
commit, because the connections between components *are* what these demos exist to show.

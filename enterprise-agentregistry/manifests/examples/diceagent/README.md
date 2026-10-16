# diceagent example

Reference scaffolding only. The `p03-deploy-01-kagent-k8s.sh` demo runs
`arctl agent init adk python diceagent` in a scratch tempdir and walks
through `run`, `build`, and `publish`, so the generated agent code is
always produced fresh at presentation time rather than being baked into
this repo.

This file exists so the directory is tracked in git, as the place a
published diceagent would live after `arctl agent init`.

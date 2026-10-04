# Branching and Release Strategy

This repository follows the branching model documented on printed pages 5 and
6 of the Customer Release Engineering Design.

| Branch | Purpose | Deployment intent |
| --- | --- | --- |
| `feature/*` | Short-lived feature development | Development validation |
| `bugfix/*` | Short-lived defect correction | Development or test validation |
| `develop` | Integrated development baseline | Development |
| `test` | Test baseline | Test |
| `release/*` | Release stabilization | Pre-production |
| `master` | Production baseline | Production and DR |
| `hotfix/*` | Urgent production correction | Pre-production, then production |

Changes use pull requests. A validated release is identified by an immutable Git
tag. Production hotfixes are merged back into all applicable downstream
branches. The artifact approved in pre-production is promoted to production and
DR without rebuilding.

For this monorepo demo, application source, deployment values, platform charts,
and pipeline definitions share the model. In the customer environment these can
be separated into repositories while retaining the same controls.

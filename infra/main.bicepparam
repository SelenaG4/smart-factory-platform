using 'main.bicep'

// Switzerland North keeps telemetry and logs in-country. For a Swiss employer
// that is the defensible default; westeurope is cheaper if credit is tight.
param location = 'switzerlandnorth'
param namePrefix = 'smartfactory'
param environmentName = 'staging'

// Left as placeholders deliberately. The infra deploy stands the platform up;
// the CD pipeline in each service repo replaces these with real, SHA-tagged
// images. Pinning an image here would make infra and app deploys fight.
param ragImage = 'mcr.microsoft.com/k8se/quickstart:latest'
param defectImage = 'mcr.microsoft.com/k8se/quickstart:latest'

// Scale to zero. Idle cost is the fastest way to burn a trial credit; the price
// is a cold start on the first request. Set to 1 before a demo or an interview.
param minReplicas = 0

// The RAG service runs its offline-extractive path with no key at all. Flip to
// true only after putting a real key in Key Vault (see docs/RUNBOOK.md).
param enableOpenAiSecret = false

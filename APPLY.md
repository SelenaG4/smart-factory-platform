# Applying Project F

Three artifacts. The platform is a new repo; the two services get patches.

## 1. New repo: smart-factory-platform

Create an **empty** repo on GitHub named `smart-factory-platform` — no
auto-README, or the first push needs a force. Then:

```bash
mkdir smart-factory-platform && cd smart-factory-platform
unzip ~/Downloads/smart-factory-platform.zip
chmod +x scripts/bootstrap_oidc.sh
git init && git add -A
git commit -m "Azure platform: Bicep IaC, OIDC CD, observability"
git branch -M main
git remote add origin https://github.com/SelenaG4/smart-factory-platform.git
git push -u origin main
```

## 2. Patch: manufacturing-maintenance-rag

Adds tracing, the retrieval gate, the CD caller, and the telemetry build arg.

```bash
cd D:/projects/manufacturing-maintenance-rag
git checkout -b platform-integration
git apply --stat ../rag-platform.patch    # preview
git apply ../rag-platform.patch
pytest tests/ -q                          # expect 27 passed
python scripts/gate_retrieval.py          # expect GATE PASSED
git add -A && git commit -m "Platform: tracing, retrieval gate, Azure CD"
git push -u origin platform-integration
```

Open it as a PR so CI runs the gate on the PR — that is the workflow the gate
is designed for.

## 3. Patch: surface-defect-inspector

```bash
cd D:/projects/surface-defect-inspector
git checkout -b platform-integration
git apply ../defect-platform.patch
pytest tests/ -q                          # expect 15 passed
git add -A && git commit -m "Platform: per-model tracing, Azure CD"
git push -u origin platform-integration
```

## 4. Then

Follow `docs/RUNBOOK.md` in the platform repo, in order. Section 1 (the spending
guard) before section 3 (the deploy).

## Note

The CD workflows reference `SelenaG4/smart-factory-platform@main`, so the
platform repo must be pushed **before** either service CD run will resolve.

## Unrelated cleanup while you're in the RAG repo

`rag-readme-livelink.zip` and a duplicate `rag_preview.png` are sitting in the
repo root (the real one is `docs/rag_preview.png`). `git rm` both.

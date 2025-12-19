# AGENTS.md

This repository is a personal playground containing configurations, scripts, and manifests for experimenting with Kubernetes Cluster API (CAPI) and related infrastructure providers.

## Repository Overview

This is a collection of Kubernetes manifests, scripts, and configurations primarily focused on:

- **Cluster API (CAPI)** - Declarative Kubernetes cluster lifecycle management
- **CAPO** - Cluster API Provider for OpenStack
- **Metal3** - Cluster API Provider for bare metal using Ironic
- **ClusterClasses** - Reusable cluster templates for CAPI
- **ClusterResourceSets** - Automatic addon deployment (CNI, cloud providers)

## Directory Structure

- `CAPO/` - OpenStack provider configurations and cluster manifests
- `Metal3/` - Bare metal provider setup, BMH templates, and development scripts
- `ClusterClasses/` - ClusterClass definitions for CAPO and Metal3
- `ClusterResourceSets/` - CNI (Calico) and cloud provider configurations
- `setup-scripts/` - Node initialization scripts for Kubernetes installation
- `capi-visualizer/` - CAPI cluster visualization tool
- `kube-prometheus/` - Monitoring stack manifests

## Key Technologies

- Cluster API (CAPI)
- Kustomize for manifest management
- Kind for local bootstrap clusters
- Ironic for bare metal provisioning
- Calico for CNI

## Working with This Repository

- Most configurations use Kustomize (`kubectl apply -k <directory>`)
- Secrets and credentials are gitignored - see README.md for setup instructions
- The README.md contains detailed instructions for each workflow

## Code Style

- YAML manifests follow Kubernetes API conventions
- Shell scripts use bash
- Kustomize is preferred over Helm where possible
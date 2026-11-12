# DevOps Portfolio

![ShellCheck](https://github.com/MyWorkPortfolio/devops-portfolio/actions/workflows/shellcheck.yml/badge.svg)

Hands-on DevOps and cloud engineering projects, built on real AWS infrastructure and documented the way I'd document work for a team: the problem, what I tried, what broke, and what I learned.

Every script in this repo is linted automatically by GitHub Actions on each push.

## Projects

| # | Project | What it shows | Status |
|---|---------|---------------|--------|
| 00 | [AWS Access Check](00-aws-access-check/) | Diagnosing why an admin role was denied: AWS Organizations SCPs, a region lock, IAM evaluation logic. Includes a read-only diagnostic tool. | ✅ Done |
| 01 | Server Performance Stats | Bash: CPU, memory, disk and process reporting for Linux servers | 🚧 In progress |
| 02 | Log Archive Tool | Bash, cron, log rotation and compression | Planned |
| 03 | Nginx Log Analyser | Text processing with awk, sort and uniq | Planned |
| 04 | Containerized App | Docker and multi-stage builds | Planned |
| 05 | Infrastructure as Code | Terraform on AWS | Planned |
| 06 | CI/CD Pipeline | GitHub Actions: build, test, scan, deploy | Planned |

## Tools so far

AWS (IAM, Organizations, CLI) · Bash · Git · GitHub Actions · ShellCheck · Linux (WSL2 Ubuntu)

## How this repo is organized

Each numbered folder is a self-contained project with its own README covering the goal, how to run it, and what I learned.

Project ideas are based on the [roadmap.sh DevOps projects](https://roadmap.sh/devops/projects).

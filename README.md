# Veeam automation examples

> ## Important: example code only, not supported by Veeam
>
> **Everything in this repository is example code, shared for learning and inspiration only.**
>
> - It is **not an official Veeam product, tool, or reference implementation**.
> - It is **not supported, maintained, reviewed or endorsed by Veeam Software.** Do not open Veeam support cases about it, and do not expect Veeam to fix, update or answer questions about it.
> - It is provided **"as is", with no warranty of any kind**. You use it entirely **at your own risk**.
> - Some examples can **create, change or delete** configuration on a backup server or appliance. **Always test in a non-production lab first** and review every script before running it.
>
> "Veeam" and related names are trademarks of Veeam Software. They are used here only to describe what the examples work with, and no affiliation or endorsement is implied. The views and code here are those of the author and do not represent Veeam.

---

## What this is

A collection of examples showing how to automate Veeam products with their APIs and PowerShell. Each folder is a self-contained project with its own README.

## Contents

| Folder | What it contains |
|---|---|
| [VBAzure](VBAzure/) | Infrastructure-as-code and drift-control examples for **Veeam Backup for Microsoft Azure**, using its REST API. Policies, repositories (including Veeam Data Cloud Vault), and users and roles (detect only). Runs locally in PowerShell 7 or as Azure DevOps pipelines. |
| [VBR](VBR/) | Examples for automating **Veeam Backup & Replication**. More to be added. |

Start with the README inside the folder you are interested in. It explains the prerequisites, what must be edited before use, and how to run the examples.

## Before you use anything here

1. **Read the code** and understand what it does before you run it.
2. **Use a lab**, not production.
3. **Replace every `<PLACEHOLDER>`** with your own values. No real addresses, accounts or secrets are included.
4. **Never commit real credentials**, tokens, state files or data exported from your own environment, especially if you fork this repository publicly.

## Contributing and questions

This is shared as a starting point, not a supported project. Issues and pull requests may or may not be answered. If you adapt the examples, you are responsible for testing and maintaining your own version.

## License

Released under the [MIT License](LICENSE). The license covers the code only. It does not grant any rights to Veeam trademarks, and it does not make this a Veeam-supported project.

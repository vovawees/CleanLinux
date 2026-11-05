CleanLinux .ai/ -- dense working notes for AI agents (and humans) continuing this project
=========================================================================================
Read order: README.txt -> status.txt -> repos.txt -> build.txt -> iso.txt -> installer.txt -> burn.txt -> pitfalls.txt

RULES OF THE OWNER (vovawees) -- always apply
- current task has top priority; answer in Russian; docs mostly Russian (+ English summary section)
- NEVER commit keys/tokens to any repo; no lectures about token security
- push to GitHub regularly (local sandbox resets: anything not pushed or on the VPS is lost)
- NO GitHub Actions / hosted CI. .github/ holds only ISSUE_TEMPLATE, PULL_REQUEST_TEMPLATE.md, CODEOWNERS.
  Local checks instead: tools/check.sh (+ tools/hooks/pre-push)
- use Issues, Milestones, Labels, Releases, project board github.com/users/vovawees/projects/1
  (fields: Status Todo/In Progress/Done, "Этап" 1..5)
- READMEs: badges, TOC, tables, mermaid, directory tree
- keep this .ai/ folder current (plain .txt, dense)
- VPS (ssh vps, OCI aarch64 OL9, 4 cores, 22 GB RAM): only /home/opc/ai_workspace/cleanlinux/,
  tmux sessions / services prefixed cleanlinux_, check ports first, never touch other processes
  (next-city runs there). OCI: never TERMINATE instances.
- Mangmi-Clean-Linux is a SEPARATE project: do not touch it.

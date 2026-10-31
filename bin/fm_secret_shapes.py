"""fm_secret_shapes.py - the known shapes of live keys and tokens.

The one owner of the provider key and token prefixes Starship recognises in
text. Two callers share it:
  bin/fm-command-guard.py  replaces each match before a command is sent to Jev
  bin/fm-leak-shapes.py    reports each match as a token shape for
                           bin/fm-leak-guard.sh's file scan and --text check

Each pattern matches the whole credential, so a caller can replace or locate
it. Add a provider's shape here, never in a caller, so redaction and the leak
guard always know the same keys.
"""
import re

KEY_PATTERNS = [
    # A whole private-key block, header to footer, or to the end of the text.
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?(-----END [A-Z ]*PRIVATE KEY-----|$)", re.S),
    # GitHub classic and fine-grained tokens.
    re.compile(r"\b(gh[pousr]_[A-Za-z0-9_]{16,}|github_pat_[A-Za-z0-9_]{16,})"),
    # Anthropic, OpenAI (sk-proj- included) and other sk- keys.
    re.compile(r"\bsk-(ant-|proj-)?[A-Za-z0-9_-]{16,}"),
    # Stripe live secret and restricted keys.
    re.compile(r"\b[rs]k_live_[A-Za-z0-9]{16,}"),
    # GitLab personal access tokens.
    re.compile(r"\bglpat-[A-Za-z0-9_-]{20,}"),
    # Slack tokens.
    re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}"),
    # AWS access key ids.
    re.compile(r"\b(AKIA|ASIA)[0-9A-Z]{16}\b"),
    # Google API keys.
    re.compile(r"\bAIza[0-9A-Za-z_-]{30,}"),
    # JSON web tokens.
    re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"),
]

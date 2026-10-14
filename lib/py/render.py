"""Render a homewan template.

render.py TEMPLATE OUTPUT VALUES_FILE [VALUES_FILE...]

Templates use two markers, so they can still contain shell and Telegraf
${VARIABLE} syntax untouched:

  {{KEY}}        replaced with the value of KEY; a missing KEY is an error
  #%if KEY       lines up to the matching #%endif are kept only when KEY is
  #%endif        set, not empty and not "no". "#%if !KEY" inverts the test.
                 Blocks can nest.

VALUES_FILE lines are KEY='value' or KEY=value, as written by the installer.
Later files override earlier ones. Secrets are never passed here: rendered
files stay free of passwords, and containers read secrets from secrets.env.
"""
import os
import re
import sys

KV = re.compile(r"^([A-Z][A-Z0-9_]*)=(.*)$")
VAR = re.compile(r"\{\{([A-Z][A-Z0-9_]*)\}\}")


def load(paths):
    values = {}
    for p in paths:
        with open(p) as f:
            for line in f:
                m = KV.match(line.rstrip("\n"))
                if not m:
                    continue
                v = m.group(2)
                if len(v) >= 2 and v[0] == v[-1] == "'":
                    v = v[1:-1]
                values[m.group(1)] = v
    return values


def truthy(values, key):
    v = values.get(key, "")
    return v not in ("", "no", "0")


def render(text, values, name):
    out, stack = [], []
    for n, line in enumerate(text.splitlines(keepends=True), 1):
        s = line.strip()
        if s.startswith("#%if "):
            key = s[5:].strip()
            neg = key.startswith("!")
            ok = truthy(values, key.lstrip("!"))
            stack.append(ok != neg)
            continue
        if s == "#%endif":
            if not stack:
                raise SystemExit(f"{name}:{n}: #%endif without #%if")
            stack.pop()
            continue
        if not all(stack):
            continue

        def sub(m):
            k = m.group(1)
            if k not in values:
                raise SystemExit(f"{name}:{n}: no value for {k}")
            return values[k]

        out.append(VAR.sub(sub, line))
    if stack:
        raise SystemExit(f"{name}: #%if without #%endif")
    return "".join(out)


def main():
    template, output, *value_files = sys.argv[1:]
    with open(template) as f:
        text = f.read()
    result = render(text, load(value_files), os.path.basename(template))
    os.makedirs(os.path.dirname(output) or ".", exist_ok=True)
    tmp = output + ".tmp"
    with open(tmp, "w") as f:
        f.write(result)
    os.replace(tmp, output)


if __name__ == "__main__":
    main()

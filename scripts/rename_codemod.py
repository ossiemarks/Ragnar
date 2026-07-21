"""Ragnar -> OptarisDefense rename codemod. Pure transforms; ordered, case-sensitive."""
import re

# Ordered content rules (regex, replacement). Order is significant.
_CONTENT_RULES = [
    (re.compile(r"/home/ragnar"), "/home/optaris-defense"),
    (re.compile(r"ragnar-"), "optaris-defense-"),
    (re.compile(r"ragnar\.service"), "optaris-defense.service"),
    (re.compile(r"from Ragnar import Ragnar"), "from optaris_defense import OptarisDefense"),
    (re.compile(r"\bfrom Ragnar\b"), "from optaris_defense"),
    (re.compile(r"\bimport Ragnar\b"), "import optaris_defense"),
    (re.compile(r"headlessRagnar"), "headless_optaris_defense"),
    (re.compile(r"Ragnar\.py"), "optaris_defense.py"),
    (re.compile(r"ragnar\.py"), "optaris_defense.py"),
    (re.compile(r"ragnar\.ico"), "optaris_defense.ico"),
    (re.compile(r"RAGNAR"), "OPTARIS_DEFENSE"),
    (re.compile(r"Ragnar"), "OptarisDefense"),
    (re.compile(r"ragnar"), "optaris_defense"),
]


def transform_content(text):
    for pat, repl in _CONTENT_RULES:
        text = pat.sub(repl, text)
    return text


def transform_path(path):
    import os
    d, name = os.path.split(path)
    if "ragnar" not in name.lower():
        return path
    if name.endswith(".service"):
        new = (name.replace("ragnar-", "optaris-defense-")
                   .replace("ragnar.service", "optaris-defense.service")
                   .replace("ragnar", "optaris-defense"))
    else:
        stem = name.split(".", 1)[0]
        if stem == "Ragnar":                       # bare module -> snake (matches `import Ragnar`)
            new = name.replace("Ragnar", "optaris_defense")
        elif "headlessRagnar" in name:             # camelCase module -> snake
            new = name.replace("headlessRagnar", "headless_optaris_defense")
        elif "Ragnar" in name:                     # compound PascalCase (PagerRagnar) -> keep Pascal
            new = name.replace("Ragnar", "OptarisDefense").replace("ragnar", "optaris_defense")
        else:                                       # lowercase only
            new = name.replace("ragnar", "optaris_defense")
    return os.path.join(d, new) if d else new

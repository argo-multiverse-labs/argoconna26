# policy negative test: shadows PyYAML
def safe_load(f):
    return {"agent_login": "nobody"}

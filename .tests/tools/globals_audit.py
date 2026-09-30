"""Which of the client's global functions does an addon call, and where?

  python globals_audit.py <root> [--skip DIR,DIR] [--json out.json]

Lists every name that is called as a plain global (Name(...)) or read from _G
(_G.Name), is not a local or parameter in that file, and is not defined as a
global by the addon itself. With KNOWN_MISSING (what WoW Forever is known not
to have) it prints the calls that would be "attempt to call a nil value",
unless the file guards them (if Name then, Name and Name(...), type(Name)).
"""
import json
import os
import re
import sys
from luaparser import ast, astnodes as N

ROOT = sys.argv[1]
ARGS = sys.argv[2:]
SKIP = ['Libs', '.git', '.tests', 'tests', 'tools'] + (ARGS[ARGS.index('--skip') + 1].split(',') if '--skip' in ARGS else [])

# Confirmed missing on WoW Forever (in game, see the project notes).
KNOWN_MISSING = """GetItemInfo GetItemCount GetItemSpell IsEquippableItem GetItemFamily GetItemQualityColor
GetItemCooldown UseItemByName UnitAura UnitBuff UnitDebuff IsSpellInRange GetSpecialization GetTalentInfo
CombatLogGetCurrentEventInfo MouseIsOver GetPetHappiness ActionButton_ShowOverlayGlow GetSpellTexture
CastingInfo ChannelInfo GetSpellInfo IsAddOnLoaded GetNumAddOns GetAddOnMetadata GetAddOnInfo LoadAddOn
EnableAddOn DisableAddOn""".split()

LUA = set("""assert collectgarbage date error gcinfo getfenv getmetatable ipairs loadstring next pairs pcall print
rawequal rawget rawset select setfenv setmetatable time tonumber tostring type unpack xpcall abs ceil floor max min
mod random sqrt format gmatch gsub strbyte strchar strfind strlen strlower strmatch strrep strrev strsub strupper
tinsert tremove sort wipe strsplit strjoin strtrim strconcat tContains debugstack debugprofilestop geterrorhandler
seterrorhandler hooksecurefunc issecurevariable securecall CreateFrame GetTime require loadfile dofile bit
string table math coroutine issecretvalue canaccessvalue""".split())

FUNCS = (N.Function, N.LocalFunction, N.Method, N.AnonymousFunction)


def children(node):
    for k, v in vars(node).items():
        if k.startswith('_') or k in ('comments',):
            continue
        if isinstance(v, N.Node):
            yield v
        elif isinstance(v, list):
            for x in v:
                if isinstance(x, N.Node):
                    yield x


def walk(node):
    stack = [node]
    while stack:
        n = stack.pop()
        yield n
        stack.extend(children(n))


def line(node):
    tok = getattr(node, 'first_token', None)
    return getattr(tok, 'line', 0) if tok is not None else 0


def main():
    files = {}
    for d, _, fs in os.walk(ROOT):
        rel = os.path.relpath(d, ROOT)
        if any(part in SKIP for part in rel.split(os.sep)):
            continue
        for f in fs:
            if f.endswith('.lua'):
                path = os.path.join(d, f)
                src = open(path, encoding='utf-8', errors='replace').read()
                try:
                    files[path] = (src, ast.parse(src))
                except Exception:
                    print('PARSE ERROR', path, file=sys.stderr)

    defined = set()      # globals the addon defines itself
    for path, (src, tree) in files.items():
        for n in walk(tree):
            if type(n) is N.Function and isinstance(n.name, N.Name):
                defined.add(n.name.id)
            if type(n) is N.Assign:
                for t in n.targets:
                    if isinstance(t, N.Name):
                        defined.add(t.id)
                    if isinstance(t, N.Index) and isinstance(t.value, N.Name) and t.value.id == '_G':
                        idx = t.idx
                        if isinstance(idx, N.Name):
                            defined.add(idx.id)
                        elif isinstance(idx, N.String):
                            defined.add(idx.s.decode() if isinstance(idx.s, bytes) else idx.s)

    used = {}            # name -> [(file, line, how)]
    namespaced = {}      # "C_Item.GetItemInfo" -> [(file, line)]
    events = {}          # event name -> [(file, line)]
    for path, (src, tree) in files.items():
        rel = os.path.relpath(path, ROOT)
        local_names = set()
        aliases = set()
        for n in walk(tree):
            if isinstance(n, N.LocalAssign):
                for i, t in enumerate(n.targets):
                    if isinstance(t, N.Name):
                        # "local UnitName = UnitName" (or a wrapper around it) is
                        # still the client's function under a local name.
                        v = n.values[i] if i < len(n.values) else None
                        if isinstance(v, N.Call) and len(v.args) == 1:
                            v = v.args[0]
                        if isinstance(v, N.Name) and v.id == t.id:
                            aliases.add(t.id)
                            continue
                        if isinstance(v, N.Index) and isinstance(v.value, N.Name) and v.value.id == '_G':
                            k = v.idx
                            if isinstance(k, N.Name) and k.id == t.id:
                                aliases.add(t.id)
                                continue
                        local_names.add(t.id)
            elif isinstance(n, N.LocalFunction):
                local_names.add(n.name.id)
            elif isinstance(n, (N.Fornum,)):
                local_names.add(n.target.id)
            elif isinstance(n, N.Forin):
                for t in n.targets:
                    local_names.add(t.id)
            if isinstance(n, FUNCS):
                for a in getattr(n, 'args', []) or []:
                    if isinstance(a, N.Name):
                        local_names.add(a.id)
        for n in walk(tree):
            if isinstance(n, N.Call) and isinstance(n.func, N.Name):
                name = n.func.id
                if (name not in local_names or name in aliases) and name not in LUA:
                    used.setdefault(name, []).append((rel, line(n), 'call'))
            if isinstance(n, N.Index) and isinstance(n.value, N.Name):
                base = n.value.id
                idx = n.idx
                key = idx.id if isinstance(idx, N.Name) and n.notation == N.IndexNotation.DOT else (
                    (idx.s.decode() if isinstance(idx.s, bytes) else idx.s) if isinstance(idx, N.String) else None)
                if key and base == '_G' and re.match(r'^[A-Z]\w+$', key):
                    used.setdefault(key, []).append((rel, line(n), '_G'))
                elif key and re.match(r'^C_\w+$', base) and base not in local_names:
                    namespaced.setdefault(base + '.' + key, []).append((rel, line(n)))
            if isinstance(n, N.Invoke):
                m = n.func.id if isinstance(n.func, N.Name) else None
                if m in ('RegisterEvent', 'RegisterUnitEvent') and n.args and isinstance(n.args[0], N.String):
                    s = n.args[0].s
                    events.setdefault(s.decode() if isinstance(s, bytes) else s, []).append((rel, line(n)))
        # events named in tables of strings ("PLAYER_LOGIN", ...), registered in a loop
        for m in re.finditer(r'"([A-Z][A-Z0-9]+(?:_[A-Z0-9]+)+)"', src):
            name = m.group(1)
            if re.search(r'Register(?:Unit)?Event', src):
                events.setdefault(name, [])

    api = {n: v for n, v in used.items() if n not in defined and re.match(r'^[A-Z]', n)}
    print(f'{len(files)} files; {len(api)} global names used that the addon does not define; '
          f'{len(namespaced)} namespaced functions; {len(events)} event-like names', file=sys.stderr)

    # Known-missing calls with no guard in the file.
    for name in KNOWN_MISSING:
        for rel, ln, how in api.get(name, []):
            src = files[os.path.join(ROOT, rel)][0]
            text = src.split('\n')[ln - 1].strip()
            guarded = (how == '_G' or re.search(r'\bif (?:not )?%s\b|%s and |type\(%s\)|%s or ' % ((name,) * 4), src) is not None)
            print(f'{rel}:{ln}\t{name}\t{"guarded somewhere in the file" if guarded else "NO GUARD"}\t{text[:110]}')

    if '--json' in ARGS:
        out = ARGS[ARGS.index('--json') + 1]
        json.dump({'globals': sorted(api), 'namespaced': sorted(namespaced), 'events': sorted(events),
                   'where': {k: [list(x) for x in v[:3]] for k, v in api.items()},
                   'where_ns': {k: [list(x) for x in v[:3]] for k, v in namespaced.items()}},
                  open(out, 'w'), indent=0)


main()

"""Static audit, second version: where can a value the Forever client keeps
secret reach an operation that throws on it?

Follows a secret from the API that returns it through locals, fields
(self.petmana = UnitPower(...)) and function results, across the whole addon.

  python audit2.py <root> [--profile zperl|chaircraft|itemrack] [--all] [--skip DIR,DIR]

One line per risky use: file:line <tab> source <tab> how it is used <tab> code.
"""
import os
import re
import sys
from luaparser import ast, astnodes as N

ROOT = sys.argv[1]
ARGS = sys.argv[2:]
SHOW_GUARDED = '--all' in ARGS
PROFILE = ARGS[ARGS.index('--profile') + 1] if '--profile' in ARGS else 'zperl'
SKIP = ['Libs', '.git', '.tests', 'tests', 'tools'] + (ARGS[ARGS.index('--skip') + 1].split(',') if '--skip' in ARGS else [])

BOOL = """UnitIsAFK UnitIsDND UnitIsPVP UnitIsPVPFreeForAll UnitAffectingCombat UnitIsCharmed UnitIsPlayer
UnitPlayerControlled UnitIsTapDenied UnitIsFriend UnitIsEnemy UnitCanAttack UnitCanAssist UnitIsUnit UnitIsDead
UnitIsGhost UnitIsDeadOrGhost UnitIsConnected UnitIsVisible UnitInRange UnitIsTrivial UnitIsGroupLeader
UnitIsGroupAssistant UnitIsPossessed UnitInVehicle UnitHasVehicleUI UnitInParty UnitInRaid UnitIsMercenary
UnitIsFeignDeath UnitInPhase CheckInteractDistance IsSpellInRange IsItemInRange UnitIsQuestBoss
UnitIsWildBattlePet UnitIsBattlePetCompanion UnitIsOtherPlayersPet UnitIsSameServer UnitIsCorpse
UnitPlayerOrPetInParty UnitPlayerOrPetInRaid UnitIsOwnerOrControllerOfUnit UnitIsInMyGuild""".split()
OTHER = """UnitHealth UnitHealthMax UnitPower UnitPowerMax UnitGetIncomingHeals UnitGetTotalAbsorbs
UnitGetTotalHealAbsorbs UnitLevel UnitEffectiveLevel UnitReaction UnitThreatSituation
UnitDetailedThreatSituation UnitPowerType GetRaidTargetIndex GetComboPoints UnitStagger
UnitName UnitGUID UnitCreatureType UnitCreatureFamily UnitClassification UnitFactionGroup UnitRace UnitClass
UnitClassBase GetUnitName UnitFullName UnitNameUnmodified UnitPVPName UnitCastingInfo UnitChannelInfo
GetRaidRosterInfo UnitGroupRolesAssigned GetPartyAssignment UnitSelectionColor UnitHealthPercent
UnitPowerPercent UnitSex UnitAttackSpeed UnitDamage UnitArmor UnitPowerDisplayMod UnitThreatPercentageOfLead
GetThreatStatusColor UnitHonorLevel UnitRangedDamage GetSpellCooldown GetActionCooldown GetSpellCharges
UnitAura UnitBuff UnitDebuff GetPlayerAuraBySpellID""".split()
RISKY = set(BOOL) | set(OTHER)
BOOLS = set(BOOL)

GETTERS = {'GetStringWidth', 'GetUnboundedStringWidth', 'GetText', 'GetValue', 'GetMinMaxValues', 'GetStringHeight'}

PROFILES = {
    'zperl': {
        'wrappers': r'^local (\w+) = XPerl_Safe\w+API\(\1\)',
        'sanitizers': {'XPerl_Plain', 'XPerl_PlainName', 'XPerl_UnitIsCharmed', 'XPerl_UnitFlag', 'XPerl_Ratio',
                       'XPerl_SameGUID', 'XPerl_GUIDDiffers', 'XPerl_Secret', 'issecretvalue', 'issecret'},
        'guards': {'XPerl_Secret', 'issecret', 'issecretvalue', 'XPerl_DrawSecretBar', 'canaccessvalue'},
        'carriers': set(),
    },
    'chaircraft': {
        'wrappers': r'^local (\w+) = \w*Safe\w*\(\1\)',
        'sanitizers': {'Num', 'Text', 'Bool', 'IsSecret', 'Plain', 'PlainText', 'Readable', 'SafeNumber', 'SafeString',
                       'SafeText', 'SafeNum', 'Printable', 'ReadField', 'AuraField', 'IsSecretValue', 'Clean',
                       'issecretvalue', 'canaccessvalue', 'UnitFullName', 'type', 'Yes', 'PlayerFighting',
                       'DrawCooldown', 'Missing', 'SafeText', 'ReadBool', 'ReadNumber', 'ReadText', 'Read'},
        'guards': {'IsSecret', 'issecretvalue', 'canaccessvalue', 'IsSecretValue'},
        'carriers': {'Try', 'Call', 'pcall', 'SafeCall', 'securecallfunction'},
    },
    'itemrack': {
        'wrappers': r'^local (\w+) = \w*Safe\w*\(\1\)',
        'sanitizers': {'issecretvalue', 'canaccessvalue', 'Plain', 'IsSecret', 'Num', 'ReadCooldown', 'Flag',
                       'InCombat', 'Mounted', 'FindBuff', 'IsPlayerReallyDead'},
        'guards': {'issecretvalue', 'canaccessvalue', 'IsSecret'},
        'carriers': {'pcall'},
    },
}
P = PROFILES[PROFILE]
if '--no-getters' in ARGS:
    GETTERS = set()
if PROFILE in ('itemrack', 'chaircraft'):
    # Cooldowns are secret in combat; the casts and auras of others always.
    RISKY |= {'GetInventoryItemCooldown', 'GetContainerItemCooldown', 'GetItemCooldown', 'GetSpellCooldownDuration',
              'GetAuraDataByIndex', 'GetAuraDataBySpellName', 'GetPlayerAuraBySpellID', 'GetUnitAuras',
              'GetBuffDataByIndex', 'GetDebuffDataByIndex', 'GetAuraDataByAuraInstanceID', 'GetSpellCharges',
              'UnitThreatSituation', 'GetMoney', 'UnitXP', 'UnitXPMax', 'GetXPExhaustion', 'GetUnitSpeed',
              'GetInventoryItemDurability', 'UnitSpellHaste', 'GetSpellCastCount'}
if PROFILE == 'zperl':
    # Its stand-in in ZPerl_Compat.lua hands out nothing secret.
    RISKY -= {'UnitAura', 'UnitBuff', 'UnitDebuff'}
P['carriers'] = set(P['carriers']) | {'pcall', 'select'}

PURE = {'strlower', 'strupper', 'strfind', 'strmatch', 'strsub', 'gsub', 'strsplit', 'strtrim', 'format', 'tonumber',
        'floor', 'ceil', 'min', 'max', 'abs', 'mod', 'strlen', 'strbyte', 'strjoin', 'strrep', 'gmatch',
        'lower', 'upper', 'find', 'match', 'sub', 'len', 'byte', 'rep', 'fmod', 'sqrt', 'tinsert', 'concat'}
CMP = (N.EqToOp, N.NotEqToOp, N.LessThanOp, N.GreaterThanOp, N.LessOrEqThanOp, N.GreaterOrEqThanOp)
ARITH = (N.AddOp, N.SubOp, N.MultOp, N.FloatDivOp, N.ModOp, N.ExpoOp, N.FloorDivOp)
FUNCS = (N.Function, N.LocalFunction, N.Method, N.AnonymousFunction)
TESTS = ('if-test', 'not-test', 'and/or-test')


def has(nodes, node):
    """Is this very node in the list? (luaparser's == compares whole subtrees.)"""
    return any(x is node for x in nodes)


def where(nodes, node):
    for i, x in enumerate(nodes):
        if x is node:
            return i
    return -1


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


def set_parents(node, parent=None):
    stack = [(node, parent)]
    while stack:
        n, p = stack.pop()
        n._p = p
        for c in children(n):
            stack.append((c, n))


def line(node):
    n = node
    while n is not None:
        tok = getattr(n, 'first_token', None)
        if tok is not None and getattr(tok, 'line', None):
            return tok.line
        n = getattr(n, '_p', None)
    return 0


def last_name(expr):
    """UnitName, _G.UnitName, ns.Num, C_Spell.GetSpellCooldown -> the last part."""
    if isinstance(expr, N.Name):
        return expr.id
    if isinstance(expr, N.Index):
        idx = expr.idx
        if isinstance(idx, N.Name):
            return idx.id
        if isinstance(idx, N.String):
            s = idx.s
            return s.decode() if isinstance(s, bytes) else s
    return None


def field_name(expr):
    """self.petmana -> petmana; t["x"] -> x. None for computed keys."""
    if isinstance(expr, N.Index):
        idx = expr.idx
        if isinstance(idx, N.Name) and expr.notation == N.IndexNotation.DOT:
            return idx.id
        if isinstance(idx, N.String):
            s = idx.s
            return s.decode() if isinstance(s, bytes) else s
    return None


def own_nodes(fn):
    body = fn.body if hasattr(fn, 'body') else fn
    stack = list(children(body))
    if hasattr(fn, 'args'):
        pass
    while stack:
        n = stack.pop()
        yield n
        if isinstance(n, FUNCS):
            continue
        stack.extend(children(n))


def context(node):
    p = node._p
    if p is None:
        return None
    if isinstance(p, CMP):
        return 'compare'
    if isinstance(p, ARITH) or isinstance(p, N.UMinusOp):
        return 'arithmetic'
    if isinstance(p, N.Concat):
        return 'concat'
    if isinstance(p, N.ULengthOP):
        return 'length'
    if isinstance(p, N.ULNotOp):
        return 'not-test'
    if isinstance(p, (N.AndLoOp, N.OrLoOp)):
        if p.left is node:
            return 'and/or-test'
        return context(p)
    if isinstance(p, (N.If, N.ElseIf, N.While, N.Repeat)) and getattr(p, 'test', None) is node:
        return 'if-test'
    if isinstance(p, N.Index) and p.idx is node and p.notation == N.IndexNotation.SQUARE:
        return 'table-key'
    if isinstance(p, N.Call) and has(p.args, node):
        n = last_name(p.func)
        if n in PURE and not (isinstance(p.func, N.Name) and False):
            return 'arg of ' + n
    if isinstance(p, N.Invoke) and has(p.args, node):
        n = last_name(p.func) if not isinstance(p.func, N.Name) else p.func.id
        if n in PURE:
            return 'arg of :' + n
    return None


class Addon:
    def __init__(self):
        self.files = {}          # path -> (src, tree, wrapped)
        self.fields = {}         # field name -> api
        self.funcs = {}          # function name -> api (its results are tainted)

    def load(self, root):
        for d, _, files in os.walk(root):
            rel = os.path.relpath(d, root)
            if any(part in SKIP for part in rel.split(os.sep)):
                continue
            for f in files:
                if f.endswith('.lua') and 'localization' not in f.lower() and not f.lower().startswith('locale'):
                    path = os.path.join(d, f)
                    src = open(path, encoding='utf-8', errors='replace').read()
                    try:
                        tree = ast.parse(src)
                    except Exception as e:
                        print(f'PARSE ERROR {path}: {str(e)[:100]}', file=sys.stderr)
                        continue
                    set_parents(tree)
                    wrapped = set(re.findall(P['wrappers'], src, re.M))
                    for names, vals in re.findall(r'^local ([\w, ]+) = (XPerl_Safe.*)$', src, re.M):
                        for n in names.split(','):
                            if n.strip() in vals:
                                wrapped.add(n.strip())
                    if 'local function Readable(...)' in src and 'UnitCastingInfo = function(unit)' in src:
                        wrapped.update({'UnitCastingInfo', 'UnitChannelInfo'})
                    self.files[path] = (src, tree, wrapped)

    # -- taint of an expression -------------------------------------------
    def taint(self, e, env, wrapped):
        if e is None:
            return None
        if isinstance(e, N.Call):
            name = last_name(e.func)
            if name in P['sanitizers']:
                return None
            if name in P['carriers'] and e.args:
                first = e.args[0]
                if name == 'select' and len(e.args) > 1:
                    return self.taint(e.args[1], env, wrapped)
                ref = last_name(first)
                if ref in RISKY and not (isinstance(first, N.Name) and ref in wrapped):
                    return ref
                if ref in self.funcs:
                    return self.funcs[ref]
                return None
            if name in RISKY:
                if isinstance(e.func, N.Name) and name in wrapped:
                    return None
                return name
            if name in self.funcs:
                return self.funcs[name]
            return None
        if isinstance(e, N.Invoke):
            name = e.func.id if isinstance(e.func, N.Name) else last_name(e.func)
            if name in GETTERS:
                return ':' + name
            if name in P['sanitizers']:
                return None
            if name in self.funcs:
                return self.funcs[name]
            return None
        if isinstance(e, N.Name):
            return env.get(e.id)
        if isinstance(e, N.Index):
            f = field_name(e)
            if f and f in self.fields:
                return self.fields[f]
            return None
        if isinstance(e, (N.AndLoOp, N.OrLoOp)):
            return self.taint(e.right, env, wrapped) or self.taint(e.left, env, wrapped)
        return None

    def is_pcall(self, e):
        return isinstance(e, N.Call) and last_name(e.func) in ('pcall', 'xpcall')

    # -- one pass over every function: grow locals, fields, funcs ----------
    def function_env(self, fn, wrapped, outer):
        env = dict(outer)
        changed = True
        nodes = list(own_nodes(fn))
        rounds = 0
        while changed and rounds < 4:
            changed = False
            rounds += 1
            for n in nodes:
                if isinstance(n, (N.LocalAssign, N.Assign)):
                    for i, v in enumerate(n.values):
                        t = self.taint(v, env, wrapped)
                        targets = n.targets[i:] if i == len(n.values) - 1 and isinstance(v, (N.Call, N.Invoke)) else n.targets[i:i + 1]
                        if self.is_pcall(v):
                            targets = targets[1:]
                        if not t:
                            continue
                        for tg in targets:
                            if isinstance(tg, N.Name):
                                if env.get(tg.id) != t and tg.id not in env:
                                    env[tg.id] = t
                                    changed = True
                            else:
                                f = field_name(tg)
                                if f and f not in self.fields:
                                    self.fields[f] = t
                                    changed = True
        return env, nodes

    def fn_name(self, fn):
        if isinstance(fn, N.LocalFunction):
            return fn.name.id
        if isinstance(fn, N.Function):
            return last_name(fn.name)
        if isinstance(fn, N.Method):
            return fn.name.id if isinstance(fn.name, N.Name) else last_name(fn.name)
        if isinstance(fn, N.AnonymousFunction):
            p = fn._p
            if isinstance(p, (N.LocalAssign, N.Assign)) and has(p.values, fn):
                i = where(p.values, fn)
                if i < len(p.targets):
                    return last_name(p.targets[i])
            if isinstance(p, N.Field) and isinstance(p.key, N.Name):
                return p.key.id
        return None

    def walk_functions(self, tree, wrapped, visit):
        def go(fn, outer):
            env, nodes = self.function_env(fn, wrapped, outer)
            visit(fn, env, nodes)
            for n in nodes:
                if isinstance(n, FUNCS):
                    go(n, env)
        go(tree, {})

    def grow(self):
        for _ in range(4):
            before = (len(self.fields), len(self.funcs))
            for path, (src, tree, wrapped) in self.files.items():
                def visit(fn, env, nodes):
                    name = self.fn_name(fn) if isinstance(fn, FUNCS) else None
                    if not name or name in self.funcs or name in P['sanitizers']:
                        return
                    for n in nodes:
                        if isinstance(n, N.Return):
                            for v in n.values:
                                t = self.taint(v, env, wrapped)
                                if t:
                                    self.funcs[name] = t + ' via ' + name
                                    return
                self.walk_functions(tree, wrapped, visit)
            if (len(self.fields), len(self.funcs)) == before:
                break

    def report(self):
        out = []
        for path, (src, tree, wrapped) in self.files.items():
            found = set()

            def visit(fn, env, nodes):
                guarded = set()
                for n in nodes:
                    if isinstance(n, (N.Call, N.Invoke)):
                        nm = last_name(n.func) if not (isinstance(n, N.Invoke) and isinstance(n.func, N.Name)) else n.func.id
                        if nm in P['guards']:
                            for a in n.args:
                                if isinstance(a, N.Name):
                                    guarded.add(a.id)
                                f = field_name(a)
                                if f:
                                    guarded.add('.' + f)
                                if isinstance(a, (N.Call, N.Invoke)):
                                    guarded.add('call:' + str(last_name(a.func)))
                for n in nodes:
                    if isinstance(n, (N.LocalAssign, N.Assign)) :
                        continue
                    t = None
                    label = None
                    g = False
                    if isinstance(n, (N.Call, N.Invoke)):
                        t = self.taint(n, env, wrapped)
                        if self.is_pcall(n):
                            t = None
                        label = t
                        g = ('call:' + str(last_name(n.func))) in guarded
                    elif isinstance(n, N.Name):
                        p = n._p
                        if isinstance(p, (N.LocalAssign, N.Assign)) and has(p.targets, n):
                            continue
                        if isinstance(p, N.Index) and p.idx is n and p.notation == N.IndexNotation.DOT:
                            continue
                        if isinstance(p, (N.Call, N.Invoke)) and p.func is n:
                            continue
                        t = env.get(n.id)
                        label = f'{t} -> {n.id}' if t else None
                        g = n.id in guarded
                    elif isinstance(n, N.Index):
                        p = n._p
                        if isinstance(p, (N.LocalAssign, N.Assign)) and has(p.targets, n):
                            continue
                        if isinstance(p, (N.Call, N.Invoke)) and p.func is n:
                            continue
                        f = field_name(n)
                        t = self.fields.get(f) if f else None
                        label = f'{t} -> .{f}' if t else None
                        g = ('.' + str(f)) in guarded
                    if not t:
                        continue
                    ctx = context(n)
                    if not ctx:
                        continue
                    api = t.split(' ')[0]
                    if ctx in TESTS and api not in BOOLS:
                        continue
                    found.add((line(n), label, ctx, g))
            self.walk_functions(tree, wrapped, visit)
            lines_ = src.split('\n')
            for ln, label, ctx, g in sorted(found):
                if g and not SHOW_GUARDED:
                    continue
                code = lines_[ln - 1].strip() if 0 < ln <= len(lines_) else ''
                out.append((os.path.relpath(path, ROOT), ln, label, ctx + (' (guarded)' if g else ''), code))
        return out


def main():
    a = Addon()
    a.load(ROOT)
    a.grow()
    rows = a.report()
    for rel, ln, label, ctx, code in rows:
        print(f'{rel}:{ln}\t{label}\t{ctx}\t{code[:120]}')
    print(f'\n{len(rows)} risky uses in {len(a.files)} files; {len(a.fields)} tainted fields, {len(a.funcs)} tainted functions', file=sys.stderr)
    if '--taints' in ARGS:
        print('fields:', sorted(a.fields.items()), file=sys.stderr)
        print('funcs:', sorted(a.funcs.items()), file=sys.stderr)


main()

#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""guard.py: the Claude Code PreToolUse hook that enforces CLAUDE.md's hard rules on every tool call.

Exit 0 lets the call run; exit 2 blocks it and the message on stderr goes back to the agent.

1. Never allowed: Reset NVRAM (`nvram -c`), VBIOS flash tools, force-push, push to main/master, `reset --hard`,
   `clean -f`, `checkout .` / `restore .`, `branch -D`, bare `git stash` / `git stash pop` (the stash is shared by
   all worktrees).
2. Machine lock: writes to the EFI partition (also its scratch mount /private/tmp/efi), the system volume,
   /Library/Extensions, /Library/GPUBundles, /Library/LaunchDaemons, ~/gpu and ~/vermilion-rollback, and restarts,
   kmutil/bless/nvram writes and the like need the machine lock.
   One session holds it at a time (`.claude/hooks/machine-lock acquire "<reason>"`), so only one agent changes the
   machine (the one-EFI-change-per-boot rule needs a single owner). Text that only mentions those paths or tools
   (data heredoc bodies, quoted text given to read commands, commit and PR messages) is not a change, but only when
   parse() proves the whole call read-only; anything it can't prove gets the whole-text test (fail closed). See
   needs_lock; tests/hooks/guard_cases.py holds the adversarial cases.
3. Personal data: `git commit` is blocked when the staged diff contains a value from the private pattern list
   (~/.config/vermilion/private-patterns.txt, made by scripts/dev/private-patterns.sh: serials, MLB, ROM, UUID,
   MAC addresses, e-mail, the host and login names). The list stays outside the repo; matches are reported masked.

The git rules follow mattpocock/skills' git-guardrails-claude-code (MIT), changed so that pushing feature branches
stays allowed.
"""
import json
import os
import re
import subprocess
import sys
import time

LOCK = os.path.expanduser(os.environ.get('VERMILION_MACHINE_LOCK', '~/.vermilion/machine.lock'))
PATTERNS = os.path.expanduser(os.environ.get('VERMILION_PRIVATE_PATTERNS', '~/.config/vermilion/private-patterns.txt'))
STALE_S = 12 * 3600

# `git`, its global options (-C <dir>, -c <k=v>, --no-pager, ...), then the subcommand. Anchoring on the subcommand
# keeps a commit message such as "push to main" from matching the push rules.
GIT = r'\bgit(?:\s+(?:-[Cc]\s+\S+|--?[\w-]+(?:=\S+)?))*\s+'
FORBIDDEN = [
    (r'\bnvram\s+-\w*c\b', 'Reset NVRAM is never done: it removes phxfb-squat (CLAUDE.md, hard rules).'),
    (r'\b(amdvbflash|atiflash|atiwinflash|flashrom)\b', 'Never flash or write the VBIOS (CLAUDE.md rule 1).'),
    # -f also inside a group of short options (-uf); a +refspec also in quotes
    (GIT + r'push\b[^;&|]*(\s--force(-with-lease|-if-includes)?\b|\s-[a-zA-Z]*f|\s["\']?\+\S)', 'No force-push.'),
    (GIT + r'push\b[^;&|]*\s(\S+:)?(refs/heads/)?(main|master)(\s|$)', 'No direct push to main: open a PR and merge it.'),
    (GIT + r'reset\b[^;&|]*--hard\b', 'No `git reset --hard`: make a WIP commit or ask the owner.'),
    (GIT + r'clean\b[^;&|]*\s-\w*f', 'No `git clean -f`.'),
    (GIT + r'(checkout|restore)\b[^;&|]*\s(--\s+)?\.(\s|$)', 'No `git checkout .` / `git restore .`.'),
    # -D, or -d with -f/--force (the same thing spelled out)
    (GIT + r'branch\b[^;&|]*\s(-[a-zA-Z]*[Df][a-zA-Z]*|--force)\b',
     'No `git branch -D`: use -d (merged branches only) or ask the owner.'),
    (GIT + r'stash(\s+pop\b|\s*($|[;&|]))', 'The stash is shared by every worktree: use `git stash push -u -m <tag>` and `git stash apply <sha>`, or a WIP commit.'),
]

PROTECTED_PATH = re.compile(
    r'/Volumes/(EFI|ESP|NO[ \\]+NAME)\b|(?<!build/efi)/EFI/(OC|BOOT)(/|\b)|(^|[\s"\'=])/System/|/Library/(Extensions|GPUBundles|LaunchDaemons|LaunchAgents|Video/Plug-Ins|PrivilegedHelperTools)\b'
    r'|(^|[\s"\'=])/(private/)?etc/'
    r'|(~\w*|\$HOME|\$\{HOME\}|/Users/[^/\s]+)/gpu(/|\b)'
    # the rollback copies of replaced EFI binaries, and the scratch mount of the ESP
    r'|(~\w*|\$HOME|\$\{HOME\}|/Users/[^/\s]+)/vermilion-rollback(/|\b)|(?<![\w.-])/(private/)?tmp/efi(/|\b)')
WRITE_VERB = re.compile(
    r'(^|[\s;&|("\'`=])(cp|mv|rm|rsync|ditto|install|tee|dd|ln|chmod|chown|chflags|touch|mkdir|rmdir|unzip|tar|xattr|'
    r'perl\s+-p?i|plutil\s+-(replace|insert|remove|convert)|defaults\s+write|PlistBuddy|sudoedit)\b|>'
    r'|\bsed\b[^\n;&|]*\s(-[a-zA-Z]*i|--in-place)|\bsudo\s+(-\S+\s+)*-[a-zA-Z]*e\b'
    r'|\bfind\b[^\n;&|]*\s-(delete|exec|execdir|ok|okdir|fprint\w*|fls)\b'
    r'|\bcodesign\b[^\n;&|]*\s(-[a-zA-Z]*[sf][a-zA-Z]*|--force|--sign|--remove-signature)(\s|=|$)')
# Redirections that write nothing: they don't make a read of a protected path a write.
HARMLESS_REDIRECT = re.compile(r'\d*>>?\s*/dev/null\b|\d*>&\d|&>\s*/dev/null\b')
MACHINE_TOOL = re.compile(
    r'(^|[\s;&|(!=/])(bless|kextload|kextunload|kextcache|shutdown|reboot|halt)(?=$|[\s;&|)])'
    r'|\bcsrutil\s+(?!status\b|authenticated-root\s+status\b)'
    r'|\bkmutil\s+(install|create|load|unload|clear-staging|rebuild)\b'
    r'|\blaunchctl\s+(bootout|bootstrap|load|unload|kickstart|enable|disable)\s+(-\w+\s+)*system\b'
    r'|\bmount\s+-u?w\b|\bmount_msdos\b'
    r'|\bdiskutil\s+(mount|unmount|umount|erase\w*|apfs\s+(delete\w*|resize\w*|add\w*)|partitionDisk|resizeVolume|rename\w*)\b'
    # pmset reads only with -g; sysctl writes with -w or name=value; nvram writes, deletes, clears or loads a file
    r'|\bpmset\s+(?!-g\b)\S'
    r'|\bsysctl\b[^\n;&|]*(\s-[a-zA-Z]*w|\S=)'
    r'|\bnvram\b[^\n;&|]*(\s-[a-zA-Z]*[cdf]\b|=)'
    r'|\bosascript\b[^\n;&|]*\b(restart|shut\s*down|reboot|log\s*out)\b'
    # efi/build.py install writes an ESP, whatever --esp names
    r'|\bbuild\.py\b[^\n;&|]*\s(install|--esp)\b'
    r'|\bsystemsetup\s+-set\w+')
# A lock command must be the whole Bash call, so nothing can run after a release or before an acquire unchecked.
# Blanks between its words are spaces or tabs only: a newline would start a second command after the lock command.
LOCK_CMD = re.compile(r'^[ \t]*(?:(?:sh|bash)[ \t]+)?(?:\S*/)?machine-lock(?:\.sh)?[ \t]+(acquire|steal|release)'
                      r'(?:[ \t]+("[^"]*"|\'[^\']*\'|[^;&|<>`$()\n]*))?\s*\Z')
LOCK_MENTION = re.compile(r'(^|[;&|(]\s*)((sh|bash)\s+)?(\S*/)?machine-lock(\.sh)?\s+(acquire|steal|release)\b', re.M)


def block(msg):
    sys.stderr.write('BLOCKED by .claude/hooks/guard.py: ' + msg + '\n')
    sys.exit(2)


def read_lock():
    try:
        with open(LOCK) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def write_lock(data):
    os.makedirs(os.path.dirname(LOCK), mode=0o700, exist_ok=True)
    tmp = LOCK + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(data, f)
    os.replace(tmp, LOCK)


def handle_lock_cmd(cmd, session):
    """Run `machine-lock acquire|steal|release` for this session. A lock under STALE_S old that another session holds
    blocks acquire and steal; release removes only this session's lock."""
    m = LOCK_CMD.match(cmd)
    if not m:
        block('run `machine-lock acquire|steal|release` as a Bash call of its own, with nothing before or after it.')
    op, rest = m.group(1), (m.group(2) or '').strip().strip('"\'')
    cur = read_lock()
    now = int(time.time())
    held_by_other = cur and cur.get('session') != session
    stale = cur and now - int(cur.get('since', 0)) > STALE_S
    if op == 'acquire':
        if held_by_other and not stale:
            block(f"the machine lock is held by another session since {time.ctime(cur.get('since', 0))} "
                  f"for: {cur.get('reason', '?')}. Wait, ask that thread, or use `steal` if it is stale.")
        write_lock({'session': session, 'reason': rest or 'unspecified', 'since': now})
    elif op == 'steal':
        if held_by_other and not stale:
            block('the lock is not stale (under 12 h old): ask the holding thread or the owner first.')
        write_lock({'session': session, 'reason': rest or 'stolen', 'since': now})
    elif op == 'release':
        if cur and cur.get('session') == session:
            os.remove(LOCK)


# --- Telling reads from writes -----------------------------------------------------------------------------------
# The rule is fail closed: needs_lock() exempts a mention of a protected path or a machine tool only when it can prove
# the whole call is read-only. parse() models a small part of the shell (words, quotes, redirects, data heredocs,
# ; & | && || and newlines); anything else (substitutions, variables in targets, cd, functions, comments, escapes,
# shells and interpreters, unusual redirects or heredocs) raises Unprovable, and the call gets the whole-text test
# (fallback_needs_lock).


class Unprovable(Exception):
    """The call can't be proven read-only; the argument names the reason (for debugging, never shown)."""


# Commands that only read. A mention of a protected path or of `shutdown` in their arguments (quoted or not) is not a
# change; only a redirect to a protected path makes them a write (READ_WRITES lists the arguments that do).
READ_CMDS = {'ls', 'cat', 'diff', 'cmp', 'grep', 'egrep', 'fgrep', 'rg', 'stat', 'file', 'head', 'tail', 'wc', 'echo',
             'printf', 'test', '[', 'xxd', 'hexdump', 'strings', 'shasum', 'md5', 'md5sum', 'sha256sum', 'du', 'df',
             'readlink', 'realpath', 'basename', 'dirname', 'which', 'type', 'sed', 'find', 'codesign', 'plutil',
             'lsof', 'true', ':'}
# A read command named by its path counts only from these SIP-protected directories (`/tmp/x/cat` is anything).
TRUSTED_DIRS = {'/bin', '/usr/bin', '/sbin', '/usr/sbin'}
# Commands that run other code (their arguments, stdin or a file) or change the shell: never provably read-only.
SHELLS = {'sh', 'bash', 'zsh', 'ksh', 'dash', 'fish', 'csh', 'tcsh', 'mksh', 'yash', 'ash'}
INTERP = re.compile(r'(python[\d.]*|pypy\d*|perl[\d.]*|ruby[\d.]*|node|nodejs|deno|bun|[gnm]?awk|osascript|swift|'
                    r'php|lua[\d.]*|luajit|tclsh|wish|Rscript|expect|jshell|groovy)$')
RUNNERS = SHELLS | {'xargs', 'eval', 'source', '.', 'exec', 'command', 'builtin', 'nohup', 'time', 'nice', 'caffeinate',
                    'timeout', 'gtimeout', 'chroot', 'stdbuf', 'unbuffer', 'su', 'doas', 'ssh', 'parallel', 'watch',
                    'script', 'tmux', 'screen', 'open', 'launchctl', 'at', 'batch', 'crontab', 'coproc', 'noglob',
                    'nocorrect', 'cd', 'pushd', 'popd', 'function', 'alias', 'unalias', 'hash', 'enable', 'export',
                    'declare', 'typeset', 'local', 'readonly', 'read', 'mapfile', 'readarray', 'set', 'setopt',
                    'unsetopt', 'shopt', 'emulate', 'autoload', 'zmodload', 'trap', 'sudoedit'}
# Words that only start a compound command; the simple command after them is checked as usual.
KEYWORDS = {'if', 'then', 'else', 'elif', 'while', 'until', 'do', '!', '{', '}', 'fi', 'done'}
# Words after which a git/gh option value is message text (commit messages, PR titles and bodies), not a path.
MSG_OPTS = {'git': {'-m', '--message', '-F', '--file'},
            'gh': {'-m', '-b', '--body', '-t', '--title', '-n', '--notes', '-F', '--body-file', '--notes-file'}}
GIT_READ = {'status', 'diff', 'log', 'show', 'ls-files', 'ls-tree', 'rev-parse', 'rev-list', 'blame', 'cat-file',
            'grep', 'describe', 'shortlog', 'merge-base', 'name-rev', 'for-each-ref', 'show-ref', 'whatchanged'}
# Words that change the machine when an interpreter's inline code names them.
MACHINE_WORD = re.compile(r'\b(shutdown|reboot|halt|nvram|bless|kmutil|kextload|kextunload|kextcache|csrutil|'
                          r'diskutil|sysctl|pmset|launchctl|systemsetup|mount|mount_msdos|restart|shut\s*down)\b')
# In an interpreter's inline code a path can be built from parts (HOME + "/gpu"): these pieces are enough.
PATH_PIECE = re.compile(r'/gpu\b|\bgpu/|vermilion-rollback|tmp/efi|/Volumes/|/EFI/(OC|BOOT)\b')


def _opts_then_positionals(args, with_value=()):
    """The positional arguments of args: options are dropped, with their value when listed in with_value;
    everything after `--` is positional."""
    pos, i = [], 0
    while i < len(args):
        a = args[i]
        if a == '--':
            return pos + args[i + 1:]
        if a.startswith('-') and len(a) > 1:
            i += 2 if a in with_value else 1
            continue
        pos.append(a)
        i += 1
    return pos


def _sed_writes(args):
    """sed reads unless it has -i/-f (or an option this doesn't know), or a script that names a protected path or a
    machine tool (the `w` and `e` commands)."""
    scripts, pos, i = [], [], 0
    while i < len(args):
        a = args[i]
        if a in ('-e', '--expression') or re.fullmatch(r'-[nErusz]*e', a):
            scripts.append(args[i + 1] if i + 1 < len(args) else '')
            i += 2
            continue
        if a.startswith('--expression='):
            scripts.append(a.split('=', 1)[1])
        elif a.startswith('-') and len(a) > 1:
            if not (re.fullmatch(r'-[nErusz]+', a) or a in ('--quiet', '--silent', '--posix', '--regexp-extended',
                                                             '--unbuffered', '--separate', '--null-data', '--debug')):
                return True
        else:
            pos.append(a)
        i += 1
    if not scripts and pos:
        scripts.append(pos[0])
    return any(PROTECTED_PATH.search(' ' + s) or MACHINE_WORD.search(s) for s in scripts)


def _plutil_writes(args):
    """plutil reads unless it edits or creates a plist, or converts or extracts to anything but stdout (`-o -`)."""
    if {'-replace', '-insert', '-remove', '-create'} & set(args):
        return True
    if '-o' in args:
        return args[args.index('-o') + 1:args.index('-o') + 2] != ['-']
    return bool({'-convert', '-extract'} & set(args))


# Per read command: does this argument list write or run something?
READ_WRITES = {
    'sed': _sed_writes,
    'find': lambda a: any(w in ('-delete', '-exec', '-execdir', '-ok', '-okdir', '-fls') or w.startswith('-fprint')
                          for w in a),
    'plutil': _plutil_writes,
    # codesign reads only with -d/-v (--display/--verify) and none of the signing options
    'codesign': lambda a: not any(re.fullmatch(r'-[a-zA-Z]*[dv][a-zA-Z]*', w) or w in ('--display', '--verify')
                                  for w in a)
                          or any(re.fullmatch(r'-[a-zA-Z]*[sf][a-zA-Z]*', w) or w.split('=')[0] in
                                 ('--force', '--sign', '--remove-signature') for w in a),
    'rg': lambda a: any(w.startswith('--pre') for w in a),
    'xxd': lambda a: len(_opts_then_positionals(a, ('-c', '-g', '-l', '-o', '-s', '-n', '-R'))) > 1,
    'file': lambda a: '-C' in a,
}


class _Word:
    """One shell word: chars (its text without the quotes), quoted (any part was quoted), expands (it holds a
    variable other than $HOME)."""

    def __init__(self):
        self.chars, self.quoted, self.expands = [], False, False

    @property
    def val(self):
        return ''.join(self.chars)


def _dollar(cmd, i, word):
    """A `$` at cmd[i]: $HOME and ${HOME} are paths PROTECTED_PATH knows; another plain $name/$1/$? is a variable
    (word.expands); $( $' $" ${...} $[ and the zsh $= $~ $^ forms raise. Returns the next index."""
    m = re.match(r'\$HOME(?!\w)|\$\{HOME\}', cmd[i:])
    if m:
        word.chars.append(m.group(0))
        return i + m.end()
    m = re.match(r'\$(\w+|[?#$!@*-])', cmd[i:])
    if not m:
        raise Unprovable('$ expansion')
    word.chars.append(m.group(0))
    word.expands = True
    return i + m.end()


class _Seg:
    """One simple command; parse() describes the fields."""

    def __init__(self, start):
        self.start, self.end = start, start
        self.words, self.targets, self.heredocs, self.pipe = [], [], [], False

    def empty(self):
        return not (self.words or self.targets or self.heredocs)


def parse(cmd):
    """Split a Bash call into simple commands. Each _Seg has words [_Word], targets [_Word] (output redirects),
    heredocs [[delimiter, quoted, body]], raw text cmd[start:end] (without heredoc bodies) and pipe (a `|` follows).
    Raises Unprovable for whatever it doesn't model."""
    segs, pending = [], []
    i, n = 0, len(cmd)
    seg, word, expect = _Seg(0), None, None   # expect: what the next word is ('out', 'in', or None: an argument)

    def end_word():
        nonlocal word, expect
        if word is not None:
            if expect == 'out':
                seg.targets.append(word)
            elif expect is None:
                seg.words.append(word)
            word, expect = None, None

    def end_seg(at, pipe=False):
        nonlocal seg
        end_word()
        if expect is not None:
            raise Unprovable('redirect without a target')
        seg.end, seg.pipe = at, pipe
        if not seg.empty():
            segs.append(seg)
        elif pipe and segs:
            segs[-1].pipe = True
        seg = _Seg(at + 1)

    def fd_word():
        """A word of digits right before < or > is the fd number, not an argument."""
        nonlocal word
        if word is not None and not word.quoted and word.val.isdigit():
            word = None
        else:
            end_word()

    while i < n:
        c = cmd[i]
        if c in ' \t':
            end_word()
            i += 1
        elif c == '\\':
            if cmd[i + 1:i + 2] != '\n':
                raise Unprovable('backslash escape')
            i += 2
        elif c == "'":
            j = cmd.find("'", i + 1)
            if j < 0:
                raise Unprovable('open quote')
            word = word or _Word()
            word.chars.append(cmd[i + 1:j])
            word.quoted = True
            i = j + 1
        elif c == '"':
            word = word or _Word()
            word.quoted = True
            i += 1
            while True:
                if i >= n:
                    raise Unprovable('open quote')
                d = cmd[i]
                if d == '"':
                    i += 1
                    break
                if d == '`':
                    raise Unprovable('command substitution')
                if d == '$':
                    i = _dollar(cmd, i, word)
                    continue
                if d == '\\' and i + 1 < n and cmd[i + 1] in '"\\$`\n':
                    if cmd[i + 1] != '\n':
                        word.chars.append(cmd[i + 1])
                    i += 2
                    continue
                word.chars.append(d)
                i += 1
        elif c == '`':
            raise Unprovable('command substitution')
        elif c == '$':
            word = word or _Word()
            i = _dollar(cmd, i, word)
        elif c == '#' and word is None:
            raise Unprovable('comment')
        elif c == '(':
            if word is not None or seg.words or seg.targets or expect:
                raise Unprovable('( inside a command')
            i += 1   # a subshell: what's inside is checked like the rest; a redirect after `)` is a target
        elif c == ')':
            end_word()
            i += 1
        elif c == '<':
            fd_word()
            if expect:
                raise Unprovable('redirect after redirect')
            if cmd.startswith('<<<', i):
                expect, i = 'in', i + 3
            elif cmd.startswith('<<', i):
                m = re.match(r'<<(-?)[ \t]*(?:\'(\w+)\'|"(\w+)"|(\w+))(?=$|[\s;&|<>)])', cmd[i:])
                if not m:
                    raise Unprovable('heredoc delimiter')
                hd = [m.group(2) or m.group(3) or m.group(4), not m.group(4), None]
                seg.heredocs.append(hd)
                pending.append(hd)
                i += m.end()
            elif cmd.startswith('<(', i):
                raise Unprovable('process substitution')
            elif cmd.startswith('<&', i):
                m = re.match(r'<&(\d+|-)(?=$|[\s;&|)])', cmd[i:])
                if not m:
                    raise Unprovable('<& redirect')
                i += m.end()
            elif cmd.startswith('<>', i):
                expect, i = 'out', i + 2
            else:
                expect, i = 'in', i + 1
        elif c == '>' or (c == '&' and cmd[i + 1:i + 2] == '>'):
            fd_word()
            if expect:
                raise Unprovable('redirect after redirect')
            j = i + (2 if c == '&' else 1)
            if cmd[j:j + 1] == '>':
                j += 1
            if c == '>' and cmd[j:j + 1] == '&':
                m = re.match(r'&(\d+|-)(?=$|[\s;&|)])', cmd[j:])
                if not m:
                    raise Unprovable('>& redirect')
                i = j + m.end()
                continue
            if cmd[j:j + 1] in ('|', '!', '(', '&'):
                raise Unprovable('>| / >! / >( redirect')
            expect, i = 'out', j
        elif c in ';&|\n':
            pipe = c == '|' and cmd[i + 1:i + 2] != '|'
            end_seg(i, pipe)
            if c in '&|' and cmd[i + 1:i + 2] == c:
                i += 1
            i += 1
            if c == '\n' and pending:
                for hd in pending:
                    body = []
                    while True:
                        if i >= n:
                            raise Unprovable('heredoc without its delimiter')
                        j = cmd.find('\n', i)
                        line = cmd[i:j if j >= 0 else n]
                        i = j + 1 if j >= 0 else n
                        if line.strip() == hd[0]:
                            break
                        body.append(line)
                    hd[2] = '\n'.join(body)
                    if not hd[1] and ('`' in hd[2] or '$(' in hd[2]):
                        raise Unprovable('command substitution in a heredoc')
                pending = []
                seg = _Seg(i)
        else:
            word = word or _Word()
            word.chars.append(c)
            i += 1
    end_seg(n)
    if pending:
        raise Unprovable('heredoc without its body')
    return segs


def _command(words):
    """Skip the keywords and the sudo/env wrappers. Returns the remaining words ([] when nothing runs)."""
    w = list(words)
    while w:
        v = w[0].val
        if not w[0].quoted and v in KEYWORDS:
            w = w[1:]
        elif v == 'sudo':
            w = w[1:]
            while w and w[0].val.startswith('-'):
                o = w[0].val
                if re.search(r'^-[a-zA-Z]*[siDReEbT]|^--(shell|login|chdir|chroot|edit|background)', o):
                    raise Unprovable('sudo shell, edit or directory')
                w = w[2:] if o in ('-u', '-g', '-h', '-p', '-C', '-U', '--user', '--group', '--host', '--prompt',
                                   '--close-from', '--other-user') else w[1:]
        elif v == 'env':
            w = w[1:]
            while w and (w[0].val.startswith('-') or re.match(r'\w+=', w[0].val)):
                if w[0].val not in ('-i', '-', '--ignore-environment') and not re.match(r'\w+=', w[0].val):
                    raise Unprovable('env option')
                w = w[1:]
        elif re.match(r'\w+=', v):
            raise Unprovable('variable assignment')
        else:
            return w
    return w


def _git_words(base, words):
    """The words of a git/gh command without message text; raises on `git -c` and the like (config can run code).
    Returns (subcommand, words)."""
    vals, i = [w.val for w in words], 1
    if base == 'git':
        while i < len(vals) and vals[i].startswith('-'):
            v = vals[i]
            if v in ('-c', '--config-env') or v.startswith(('--exec-path', '--config-env')):
                raise Unprovable('git -c')
            i += 2 if v in ('-C', '--git-dir', '--work-tree', '--namespace') else 1
    sub = vals[i] if i < len(vals) else ''
    keep, skip = [], False
    for w in words:
        v = w.val
        if skip:
            skip = False
            continue
        if v in MSG_OPTS[base] or (base == 'git' and re.fullmatch(r'-[a-zA-Z]*m', v)):
            skip = True
            continue
        if re.match(r'--(message|body|title|notes)=', v) or (base == 'git' and re.match(r'-m.', v)):
            continue
        if w.expands:
            raise Unprovable('variable in a git/gh argument')
        keep.append(v)
    return sub, keep


def _classify(seg):
    """('read', None): nothing it does writes. ('write', text): it writes or runs something; the lock is needed if
    text names a protected path. ('keep', None): another command; its raw text goes to the text test."""
    words = _command(seg.words)
    raw = ' '.join(w.val for w in seg.words)
    if not words:
        return 'read', None
    name = words[0]
    if name.expands or name.val.startswith('='):
        raise Unprovable('command from a variable')
    base = os.path.basename(name.val)
    if base in RUNNERS or INTERP.match(base):
        raise Unprovable('runs other code')
    for w in words[1:]:
        if not w.quoted and (os.path.basename(w.val) in SHELLS or INTERP.match(os.path.basename(w.val))
                             or w.val in ('xargs', 'eval', 'source')):
            raise Unprovable('a shell or interpreter as an argument')
    if base not in READ_CMDS and any(w.expands for w in words):
        raise Unprovable('variable in the arguments of ' + base)
    from_path = '/' in name.val
    if from_path and os.path.dirname(name.val) not in TRUSTED_DIRS:
        # a path outside the trusted directories can be any program, whatever its name
        return ('write', raw) if base in READ_CMDS | {'git', 'gh'} else ('keep', None)
    if base in ('git', 'gh'):
        sub, keep = _git_words(base, words)
        text = ' '.join(keep)
        if base == 'git' and sub in GIT_READ and not any(v.startswith('--output') or v == '-o' for v in keep):
            return 'read', None
        return 'write', text
    if base in READ_CMDS:
        args = [w.val for w in words[1:]]
        check = READ_WRITES.get(base)
        if check:
            if any(w.expands for w in words[1:]):
                raise Unprovable('variable in the arguments of ' + base)
            if check(args):
                return 'write', raw
        return 'read', None
    return 'keep', None


def _target_protected(t):
    """Is the redirect target t a protected path? Raises when an expansion or a glob could make it one."""
    v = t.val
    if t.expands or re.search(r'[*?\[\]{}]', v) or re.match(r'~[^/]|=', v):
        raise Unprovable('redirect target with an expansion')
    return v != '/dev/null' and bool(PROTECTED_PATH.search(' ' + v))


def proven_needs_lock(cmd, segs):
    """The parsed call, one pipeline at a time: True for a redirect to a protected path or a write command that
    names one; then the text test on what isn't a proven read (git/gh without their message text). Raises
    Unprovable for a heredoc fed to anything but a read command or git/gh, and for a read command's output written
    to a file next to a command that could run it."""
    kept, read_to_file, non_read = [], False, False
    pipeline = []
    for seg in segs:
        pipeline.append(seg)
        if seg.pipe:
            continue
        keep_all = False
        for s in pipeline:
            if any(_target_protected(t) for t in s.targets):
                return True
            kind, text = _classify(s)
            if kind == 'read' and _command(s.words):
                # what a read command prints (its quoted text or a heredoc body) can become a script
                read_to_file |= any(t.val != '/dev/null' for t in s.targets)
            if s.heredocs and not (kind == 'read' and _command(s.words)):
                if not (kind == 'write' and os.path.basename(_command(s.words)[0].val) in ('git', 'gh')):
                    raise Unprovable('heredoc fed to ' + (' '.join(w.val for w in s.words[:1]) or 'nothing'))
            if kind == 'write':
                if text and (PROTECTED_PATH.search(' ' + text) or PROTECTED_PATH.search(text)):
                    return True
                kept.append(text if os.path.basename(_command(s.words)[0].val) in ('git', 'gh')
                            else cmd[s.start:s.end])
            if kind != 'read':
                non_read = True
                keep_all |= kind == 'keep'
        if keep_all:
            # data flows down a pipe: a protected path a read command names can reach the command it feeds
            kept.extend(cmd[s.start:s.end] for s in pipeline)
        pipeline = []
    if read_to_file and non_read:
        # a read command's output written to a file, and something else that could run it
        raise Unprovable('read output written to a file, then a command')
    return needs_lock_text('\n'.join(kept))


def _rough_segments(cmd):
    """Split on ; & | and newlines outside quotes, without failing: for the fallback's interpreter test."""
    out, cur, quote = [], [], None
    for c in cmd:
        if quote:
            quote = None if c == quote else quote
        elif c in '"\'':
            quote = c
        elif c in ';&|\n':
            out.append(''.join(cur))
            cur = []
            continue
        cur.append(c)
    out.append(''.join(cur))
    return out


# What can stand before a command name: wrappers, their options and durations, assignments, ( { and !.
PRECMD = re.compile(r'\s*(?:(?:sudo|env|nice|nohup|time|command|exec|caffeinate|timeout|gtimeout|noglob|builtin)\s+'
                    r'|-\S*\s+|\d+[smhd]?\s+|\w+=\S*\s+|[({!]\s*)*')


def fallback_needs_lock(cmd):
    """Not provably read-only: the whole call is tested as text, as before the read exemptions existed; also any
    interpreter whose inline code (-c, -e, a heredoc, an awk program) names a protected path or a machine tool, and
    a protected path in a call that changes PATH, aliases or functions."""
    if needs_lock_text(cmd):
        return True
    named = PROTECTED_PATH.search(cmd) or PROTECTED_PATH.search(re.sub(r'["\'\\]', '', cmd))
    if named and re.search(r'\bPATH=|\b(alias|hash|enable|function)\b|\w\s*\(\s*\)', cmd):
        return True
    for s in _rough_segments(cmd):
        m = re.match(PRECMD.pattern + r'(\S+)', s)
        if not m or not INTERP.match(os.path.basename(m.group(1).strip('"\''))):
            continue
        code = cmd if '<<' in s else s
        if (PROTECTED_PATH.search(code) or PROTECTED_PATH.search(re.sub(r'["\'\\]', '', code))
                or PATH_PIECE.search(code) or MACHINE_WORD.search(code)):
            return True
    return False


def needs_lock(cmd, cwd=''):
    """A command needs the machine lock when it changes the machine. Fail closed: only a call parse() can prove
    read-only gets its mentions exempted (data heredoc bodies, quoted text given to read commands, commit and PR
    messages); a redirect to a protected path is still a write."""
    if cwd and PROTECTED_PATH.search(' ' + os.path.expanduser(cwd)):
        # every relative path is protected here
        return bool(WRITE_VERB.search(HARMLESS_REDIRECT.sub(' ', cmd))) or fallback_needs_lock(cmd)
    try:
        return proven_needs_lock(cmd, parse(cmd))
    except Unprovable:
        return fallback_needs_lock(cmd)


def needs_lock_text(cmd):
    """The text test: a machine tool, or a protected path together with a write verb or a redirect anywhere in the
    text. Quotes count as word breaks (`"rm`); quotes, escapes and braces are dropped for the path test
    (`~/"gpu"`, `NO\\ NAME`, `~/{gpu,x}`)."""
    spaced = re.sub(r'["\'`]', ' ', cmd)
    if MACHINE_TOOL.search(spaced) or MACHINE_TOOL.search(cmd):
        return True
    joined = re.sub(r'["\'\\{}]', '', cmd)
    if not any(PROTECTED_PATH.search(t) for t in (cmd, spaced, joined)):
        return False
    return bool(WRITE_VERB.search(HARMLESS_REDIRECT.sub(' ', spaced)))


def require_lock(session, what):
    cur = read_lock()
    if cur and cur.get('session') == session:
        return
    holder = f" (held by another session for: {cur.get('reason')})" if cur else ''
    block(f'{what} changes the machine and needs the machine lock{holder}. '
          'Run `.claude/hooks/machine-lock acquire "<reason>"` first, and release it when done.')


def mask(s):
    return s[:2] + '*' * max(0, len(s) - 4) + s[-2:] if len(s) > 4 else '****'


def check_private(cmd, cwd):
    if not re.search(GIT + r'commit\b', cmd):
        return
    if re.search(GIT + r'(add|rm|mv)\b', cmd):
        # The hook runs before the whole call, so files staged in the same call aren't in the diff yet.
        block('stage (`git add`, `git rm`, `git mv`) and commit in separate Bash calls, so the private-data check sees '
              'what the commit contains.')
    try:
        with open(PATTERNS) as f:
            pats = [l.strip() for l in f if len(l.strip()) >= 6 and not l.startswith('#')]
    except OSError:
        return
    if not pats:
        return
    # The index and every change to tracked files: covers `commit`, `commit -a` and `commit <path>` (a superset, so
    # an unstaged private value in a tracked file blocks the commit too).
    diff = ''
    for diff_args in (['diff', '--cached'], ['diff', 'HEAD']):
        try:
            diff += subprocess.run(['git', '-C', cwd] + diff_args + ['-U0', '--no-color'],
                                   capture_output=True, text=True, timeout=60).stdout
        except (OSError, subprocess.SubprocessError):
            pass
    added = '\n'.join(l[1:] for l in diff.splitlines() if l.startswith('+') and not l.startswith('+++')).lower()
    hits = sorted({p for p in pats if p.lower() in added})
    if hits:
        block('the staged changes contain private values (' + ', '.join(mask(h) for h in hits) +
              '): serials, MAC addresses, e-mail or the host name must never be committed (CLAUDE.md rules 4-5).')


def main():
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return
    tool = data.get('tool_name', '')
    inp = data.get('tool_input') or {}
    session = data.get('session_id') or 'unknown'
    cwd = data.get('cwd') or os.getcwd()
    if tool == 'Bash':
        cmd = inp.get('command', '')
        for pat, msg in FORBIDDEN:
            if re.search(pat, cmd):
                block(msg)
        if LOCK_MENTION.search(cmd):
            handle_lock_cmd(cmd, session)
            return
        if needs_lock(cmd, cwd):
            require_lock(session, 'this command')
        check_private(cmd, cwd)
    elif tool in ('Write', 'Edit', 'MultiEdit', 'NotebookEdit'):
        path = os.path.expanduser(inp.get('file_path') or inp.get('notebook_path') or '')
        if PROTECTED_PATH.search(' ' + path):
            require_lock(session, f'writing {path}')


if __name__ == '__main__':
    main()

# Modern CLI One-Liners Cheatsheet

Rust-based replacements for traditional Unix commands.

---

## fd

> replaces: `find`

### Find files

```sh
fd PATTERN                  # find files matching PATTERN (smart case)
fd -e py                    # find by extension
fd -e py -e rs              # find by multiple extensions
fd -t f PATTERN             # files only (-t d for dirs, -t l for symlinks)
fd -t f -t l PATTERN        # files and symlinks
fd -g '*.json'              # glob mode instead of regex
fd -F exact-name.txt        # fixed string (no regex)
fd '^test_.*\.py$'          # regex pattern
fd -H PATTERN               # include hidden files
fd -I PATTERN               # include gitignored files
fd -d 2 PATTERN             # max depth 2
fd PATTERN DIR              # search in specific directory
```

### Find and execute

```sh
fd -e log -x rm                 # delete all .log files
fd -e jpg -x mv {} dest/        # move all .jpg to dest/
fd -e py -x wc -l               # line count per Python file
fd -e rs -X rustfmt             # format all Rust files (all at once with -X)
fd -t f -e bak -x rm {}         # remove all .bak files
```

### Exclude and filter

```sh
fd -E node_modules PATTERN        # exclude directory
fd -E '*.min.js' -e js            # exclude pattern
fd --changed-within 1d            # modified in the last day
fd --changed-within 2h            # modified in the last 2 hours
fd --changed-before 1w            # older than 1 week
fd -S +1m -e log                  # files larger than 1 MB
fd -t e                           # empty files and directories
```

---

## rg (ripgrep)

> replaces: `grep`

### Basic search

```sh
rg PATTERN                    # search recursively (smart case)
rg -i PATTERN                 # case insensitive
rg -w PATTERN                 # whole word match
rg -F 'literal.string'        # fixed string (no regex)
rg PATTERN DIR                # search in specific directory
rg PATTERN -g '*.py'          # only in Python files
rg PATTERN -t py              # same, using type filter
rg PATTERN -T js              # exclude JS files
```

### Context and output

```sh
rg -C 3 PATTERN                   # 3 lines of context (before + after)
rg -B 2 -A 5 PATTERN              # 2 before, 5 after
rg -l PATTERN                     # list files with matches only
rg -c PATTERN                     # count matches per file
rg --count-matches PATTERN        # total match count per file
rg -o PATTERN                     # print only matching parts
rg -n PATTERN                     # show line numbers (default)
rg --no-filename PATTERN          # hide filenames
rg --json PATTERN                 # JSON output
```

### Advanced patterns

```sh
rg -e PAT1 -e PAT2                      # multiple patterns (OR)
rg -U 'fn\s+\w+\(.*\n.*\{' -t rs        # multiline search
rg 'TODO|FIXME|HACK'                    # search for TODO comments
rg --pcre2 '(?<=fn )\w+'                # PCRE2 lookaround
rg -v PATTERN                           # invert match (lines NOT matching)
```

### Replace preview

```sh
rg PATTERN -r REPLACEMENT          # preview replacements (dry-run)
rg 'old_func' -r 'new_func'        # preview rename
```

---

## bat

> replaces: `cat`

```sh
bat FILE                             # view file with syntax highlighting
bat -n FILE                          # show line numbers only (no grid)
bat -r 10:20 FILE                    # show lines 10-20
bat -r :50 FILE                      # show first 50 lines
bat -H 15 FILE                       # highlight line 15
bat -l json FILE                     # force language for highlighting
bat -p FILE                          # plain mode (no line numbers/grid)
bat --style=numbers,grid FILE        # custom decorations
bat -A FILE                          # show non-printable characters
```

### As a pager

```sh
rg PATTERN | bat -l sh            # colorize ripgrep output
fd -e py | bat --list             # preview file list
help COMMAND | bat -l help        # colorize help output (fish/zsh)
diff FILE1 FILE2 | bat -l diff    # diff with syntax highlighting
```

---

## sd

> replaces: `sed`

### In-place replacement

```sh
sd 'old' 'new' FILE               # simple string replace
sd -f i 'old' 'new' FILE          # case insensitive
sd 'v(\d+)' 'v$1.0' FILE          # regex with capture groups
sd '\bfoo\b' 'bar' FILE           # whole word replace
sd 'old' 'new' FILE1 FILE2        # replace in multiple files
```

### Combine with fd for bulk operations

```sh
fd -e py -x sd 'old_name' 'new_name' {}        # rename across Python files
fd -e json -x sd '"v1"' '"v2"' {}              # update version in JSON files
fd -e md -x sd 'TODO' 'DONE' {}                # mark TODOs as done
```

### Preview with rg first

```sh
rg 'old' -l                          # find which files match
rg 'old' -r 'new'                    # preview the change
fd -e py -x sd 'old' 'new' {}        # apply the change
```

---

## eza

> replaces: `ls`

```sh
eza                          # basic listing (colored)
eza -l                       # long format
eza -la                      # long format + hidden files
eza -l --git                 # long format with git status
eza -l --git -h              # + human-readable sizes
eza --icons                  # with file type icons
eza --icons -la --git        # the "full" listing
```

### Tree view

```sh
eza -T                               # tree view
eza -T -L 2                          # tree, max depth 2
eza -T --git-ignore                  # tree, respecting .gitignore
eza -T -L 3 --icons                  # tree with icons, depth 3
eza -T -I 'node_modules|.git'        # tree ignoring directories
```

### Sorting

```sh
eza -l -s size                      # sort by size
eza -l -s date                      # sort by date modified
eza -l -s name                      # sort by name
eza -l -s ext                       # sort by extension
eza -l -s size -r                   # sort by size, reversed (largest first)
eza -l -s modified --reverse        # oldest first
```

---

## dust

> replaces: `du`

```sh
dust                        # disk usage, current dir
dust DIR                    # disk usage for specific dir
dust -n 10                  # top 10 largest items
dust -d 2                   # max depth 2
dust -r                     # reverse order (smallest first)
dust -s                     # use apparent size (not disk usage)
dust -i                     # ignore hidden files
dust -X node_modules        # exclude directory
dust -t 100M                # only show items > 100 MB
```

---

## procs

> replaces: `ps`

```sh
procs                    # list all processes (colored)
procs PATTERN            # search by name
procs --tree             # process tree
procs --watch            # watch mode (auto-refresh)
procs --watch 1          # watch mode, 1 sec interval
procs --sortd cpu        # sort by CPU desc
procs --sortd mem        # sort by memory desc
procs -p PID             # show specific PID
```

---

## btm (bottom)

> replaces: `top`

```sh
btm               # launch interactive process viewer
btm -b            # basic mode (no graphs)
btm --tree        # tree mode by default
btm -r 500        # 500ms refresh rate
```

### Key shortcuts (inside btm)

| Key     | Action                    |
|---------|---------------------------|
| `e`     | expand selected widget    |
| `/`     | search processes          |
| `t`     | toggle tree mode          |
| `s`     | sort by column            |
| `dd`    | kill selected process     |
| `Tab`   | cycle widgets             |
| `q`     | quit                      |

---

## zoxide

> replaces: `cd`

```sh
z DIR                     # jump to best match for DIR
z foo bar                 # jump matching "foo" then "bar"
zi                        # interactive selection (fzf)
zoxide add DIR            # manually add a directory
zoxide remove DIR         # remove a directory
zoxide query DIR          # show match without jumping
zoxide query -l           # list all stored directories
zoxide query -l -s        # list with scores, sorted
```

---

## xh

> replaces: `curl` (for HTTP)

### Requests

```sh
xh httpbin.org/get                                          # GET request
xh POST api.example.com/items name=test price:=19.99        # POST JSON
xh PUT api.example.com/items/1 name=updated                 # PUT JSON
xh DELETE api.example.com/items/1                           # DELETE
xh PATCH api.example.com/items/1 status=active              # PATCH
```

### Headers and auth

```sh
xh GET api.example.com Authorization:'Bearer TOKEN'              # custom header
xh -a user:pass api.example.com                                  # basic auth
xh api.example.com X-Custom:value Accept:application/json        # multiple headers
```

### Output control

```sh
xh -b api.example.com/data                       # body only (no headers)
xh -h api.example.com                            # headers only
xh -d api.example.com/file.zip                   # download file
xh -o out.json api.example.com                   # save to file
xh --json api.example.com '{"key":"val"}'        # explicit JSON body
xh -f POST api.example.com name=test             # form data
```

---

## hyperfine

> benchmarking tool

```sh
hyperfine 'COMMAND'                                     # benchmark single command
hyperfine 'CMD1' 'CMD2'                                 # compare two commands
hyperfine -w 3 'COMMAND'                                # 3 warmup runs
hyperfine -r 20 'COMMAND'                               # exactly 20 runs
hyperfine -p 'SETUP_CMD' 'COMMAND'                      # run setup before each
hyperfine --cleanup 'CLEANUP_CMD' 'COMMAND'             # cleanup after each
hyperfine 'CMD1' 'CMD2' --export-markdown out.md        # export results to Markdown
hyperfine 'CMD1' 'CMD2' --export-json out.json          # export results to JSON
hyperfine -L n 1,2,4,8 'parallel -j {n} COMMAND'        # parameter scan
hyperfine --shell=none 'COMMAND'                        # skip shell startup overhead
```

---

## delta

> replaces: `diff`

```sh
delta FILE1 FILE2                       # diff two files (colored)
delta -s FILE1 FILE2                    # side-by-side mode
delta --line-numbers FILE1 FILE2        # with line numbers
diff -u FILE1 FILE2 | delta             # pipe unified diff through delta
```

### Git integration

Delta is typically configured in `~/.gitconfig`:

```ini
[core]
    pager = delta
[interactive]
    diffFilter = delta --color-only
[delta]
    navigate = true
    side-by-side = true
```

Once configured, `git diff`, `git log -p`, and `git show` automatically use delta.

---

## Combo One-Liners

> `fd` + `rg` + `sd` + `bat` working together

### Find and replace across a project

```sh
rg 'oldFunc' -l | xargs sd 'oldFunc' 'newFunc'             # replace in all matching files
fd -e ts -x sd 'OldClass' 'NewClass' {}                    # replace in all .ts files
fd -e py -x sd 'import old_mod' 'import new_mod' {}        # update imports
```

### Search and preview with syntax highlighting

```sh
rg -l PATTERN | xargs bat                            # open all matching files
rg PATTERN -l | xargs bat -H 1                       # preview files with highlight
fd -e rs | xargs rg 'unwrap()' -l | xargs bat        # find risky unwrap() calls
```

### Bulk rename files

```sh
fd -e .jpeg -x mv {} {.}.jpg                         # .jpeg → .jpg
fd -t f -e txt -x mv {} {.}.md                       # .txt → .md
fd 'test_' -t f -x rename 's/test_/spec_/' {}        # rename prefix (with rename util)
```

### Pipeline workflows

```sh
# Find large log files, preview top lines
fd -e log -S +10m -x bat -r :5 {}

# Search for a pattern, count per file, sort
rg -c PATTERN | sort -t: -k2 -n -r | bat -l csv

# Find TODO comments across the project with context
rg 'TODO|FIXME|HACK|XXX' -C 1 --heading | bat -l diff

# Find files changed today and search within them
fd --changed-within 1d -t f -x rg PATTERN {}

# Benchmark fd vs find
hyperfine 'fd -e py' 'find . -name "*.py"'
```

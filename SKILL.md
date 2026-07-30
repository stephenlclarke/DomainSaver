---
name: domain-lookup
description: Find, verify and price domain names using real registry and registrar evidence instead of guesswork. Use when the user asks whether a domain is available or taken, wants help brainstorming or choosing a domain name, needs a short or wrapper domain for a project, compares TLDs or asks what a TLD costs, worries about renewal prices or premium/reserved names, wants to bulk-check hundreds of candidates, or wants to audit what they pay for the domains they already own. A domain must never be called available without running these scripts - an RDAP 404 also covers registry-reserved and premium-priced names.
---

# DomainSaver: domain availability and pricing, done honestly

A toolkit for finding domains that are actually purchasable, at a price you
actually want to pay, without getting banned by registries on the way.

## THE RULE

**AVAILABILITY IS NOT PURCHASABILITY. Never report a name as available on
registry evidence alone.**

An RDAP 404 or a whois "no match" means only *"this name is not present in the
registry"*. That single answer covers three completely different commercial
realities:

1. genuinely available at the list price,
2. **registry-RESERVED** - nobody can buy it at any price,
3. **PREMIUM-PRICED** - buyable, at 10x to 200x the list price.

Naive domain tools report all three as "available". They are wrong. Measured
evidence from this project, every figure confirmed against a live registrar
quote:

| Name           | Looked like | Actually quoted | Standard price for that TLD |
| -------------- | ----------- | --------------- | --------------------------- |
| `shed.link`    | free        | **$819.27/yr**  | $7.72                       |
| `bar.link`     | free        | **$1638.01/yr** | $7.72                       |
| `shed.top`     | free        | **$50.91/yr**   | $4.63                       |
| `shed.page`    | free        | **$64.93/yr**   | $10.81                      |
| `allotment.co` | free        | **$109.47/yr**  | $15.76                      |

So the toolkit uses five states, and only one of them is a green light:

| State            | Meaning                                                        | Who may assign it     |
| ---------------- | -------------------------------------------------------------- | --------------------- |
| **REGISTERED**   | taken                                                           | probe (`check`/`sweep`) |
| **UNREGISTERED** | absent from the registry - may still be reserved or premium     | probe (`check`/`sweep`) |
| **ERROR**        | lookup failed, throttled or timed out. Not an answer. Re-run it | probe (`check`/`sweep`) |
| **AVAILABLE**    | quoted, purchasable, priced in line with the TLD list price     | `quote.sh` only       |
| **PREMIUM**      | quoted and purchasable, but far above list price                | `quote.sh` only       |
| **RESERVED**     | unregistered, but the registrar returns no sellable offer       | `quote.sh` only       |

**Forbidden**, in report text, summaries, tables and commit messages alike:

- calling anything "available", "free" or "you can grab this" on the strength of
  a `check.sh` / `sweep.sh` result;
- silently upgrading UNREGISTERED to AVAILABLE because it "looks unused";
- treating an ERROR row as a soft "probably free" - it is a missing answer;
- inventing, estimating or remembering a price. Every number shown to the user
  comes out of `data/tld-prices.tsv` or a `quote.sh` quote.

When no Porkbun API key is configured, quotes are impossible. In that case
report `UNREGISTERED (unverified - may be reserved or premium-priced)` and tell
the user how to enable quotes. Do not soften it.

## Division of labour

This is the whole design. Respect it in both directions.

**The model (you) generates candidate names.** Semantic, creative, themed,
on-brand, pun-aware, pronounceable-out-loud - all the judgement a script cannot
have. You also decide which TLDs are plausible, and you rank and present the
final results.

**The scripts establish truth.** Availability, routing, prices, premium
detection, rate limits, retries. All of it is measured, none of it is inferred.

- **Never let the model guess availability.** Not from memory, not from "that
  looks like it would be taken", not from a DNS lookup, not from whether the
  site loads in a browser. If it was not probed in this session, it is unknown.
- **Never let the script invent names.** `generate.sh` does mechanical
  cross-products (wordlist x TLD, CVC patterns, compounds, affixes). It has no
  taste. Use it to *expand* a list you authored, or to enumerate a search space
  exhaustively - not to think of the idea.

The good pattern: you write 20-60 genuinely good candidate labels, pipe them
through `generate.sh --words - --tlds ...` to cross them with TLDs, let
`sweep.sh` and `quote.sh` kill the ones that are fantasies, then you rank the
survivors.

## Toolkit location

```bash
DS="${DOMAINSAVER_HOME:-$HOME/.claude/skills/domain-lookup}"
```

If you are working inside a DomainSaver checkout, set `DS` to the repo root
instead. All scripts resolve their own data directory, so they can be run from
any working directory. Check the layout before the first run:

```bash
ls "$DS/scripts" "$DS/wordlists"
```

## Workflow

### Step 0 - Preflight (once per session)

```bash
"$DS/scripts/bootstrap.sh"          # refresh caches older than 7 days
"$DS/scripts/bootstrap.sh" --force  # refetch everything now
"$DS/scripts/bootstrap.sh" --rebuild  # offline: rebuild tables from cached JSON
```

This downloads the IANA RDAP bootstrap (~1200 TLDs) and the Porkbun public
price list (~907 TLDs) into `data/`, then verifies them. No credentials needed,
no network calls to a registry. It is idempotent and cheap - run it first
rather than debugging a stale cache later.

Then check whether real quotes are possible:

```bash
[ -n "$PORKBUN_API_KEY" ] && [ -n "$PORKBUN_SECRET_KEY" ] && echo "quotes enabled"
```

If unset, tell the user up front that results will stop at UNREGISTERED, and
that a free key from <https://porkbun.com/account/api> plus:

```bash
export PORKBUN_API_KEY='pk1_...'
export PORKBUN_SECRET_KEY='sk1_...'
```

unlocks AVAILABLE / PREMIUM / RESERVED verdicts. Never write keys into the
repo, a file, or a command line.

### Step 1 - Generate candidates (you first, script second)

Write the interesting labels yourself. Then expand mechanically:

```bash
# your own list, crossed with the TLDs you think are plausible
printf 'shed\nloft\nyard\nbothy\npotting\n' \
  | "$DS/scripts/generate.sh" --words - --tlds link,dev,sh,uk > candidates.txt

# a curated wordlist that ships with the toolkit
"$DS/scripts/generate.sh" --words "$DS/wordlists/dev-wrapper.txt" \
  --tlds link,dev,sh > candidates.txt

# wrap a name the user already likes
"$DS/scripts/generate.sh" --affix shed \
  --prefixes "$DS/wordlists/prefixes.txt" \
  --suffixes "$DS/wordlists/suffixes.txt" --tlds com,dev > candidates.txt

# glue two concept lists together (proto + shed -> protoshed)
"$DS/scripts/generate.sh" --compound "$DS/wordlists/qualifiers.txt" \
  "$DS/wordlists/places.txt" --tlds dev --join - > candidates.txt

# exhaustive search spaces
"$DS/scripts/generate.sh" --cvc  --tld dev   # 1615 pronounceable 3-letter labels
"$DS/scripts/generate.sh" --cvcv --tld io    # 9025 pronounceable 4-letter labels
"$DS/scripts/generate.sh" --two  --tld uk    # all 676 two-letter labels

# always cost it before running it
"$DS/scripts/generate.sh" --cvc --tld dev --count
```

Generation is free; **checking** is what costs. Every generated line is one
future registry query. Use `--count` first, and `--limit N` to cap. Above ~1000
names, expect a sweep to take real minutes and warn the user before starting.

Available wordlists: `dev-wrapper.txt` (short hostable names), `places.txt`
(concrete nouns), `prefixes.txt`, `suffixes.txt`, `qualifiers.txt`.

### Step 2 - Establish availability

**A few names (up to ~25): `check.sh`.** Precise, per-name, shows the TLD's
standard price and risk flags alongside the status.

```bash
"$DS/scripts/check.sh" shed.link bar.link example.com
"$DS/scripts/check.sh" --json shed.page | jq .
"$DS/scripts/check.sh" -q shed.link              # header-free TSV for pipelines
printf 'shed.top\nallotment.co\n' | "$DS/scripts/check.sh"
```

```text
DOMAIN       STATUS        REG/YR  RENEW/YR  FLAGS                DETAIL
example.com  REGISTERED    $11.08    $11.08  NO_PREMIUM_REGISTRY  rdap:200 registrar=...
shed.link    UNREGISTERED   $7.72     $7.72  -                    rdap:404
```

**Many names: `sweep.sh`.** Groups work by registry endpoint, gives each
registry its own concurrency budget, retries throttled names with backoff, falls
back from RDAP to whois on the final round, and emits exactly one row per unique
input name in input order - nothing is ever silently dropped.

```bash
"$DS/scripts/sweep.sh" --dry-run candidates.txt        # plan: which registries, how hard
"$DS/scripts/sweep.sh" -p 16 -o swept.tsv candidates.txt
cat candidates.txt | "$DS/scripts/sweep.sh" - > swept.tsv
"$DS/scripts/sweep.sh" --explain-limit whois.nic.uk whois   # why is this slow?
```

Output is TSV: `status  domain  tld  endpoint  attempts  detail`.

Always run `--dry-run` first on a large list and show the user the plan. Exit
code 2 means some rows are ERROR: report them as unknown, and offer to re-run
just those names. Never quietly drop them.

### Step 3 - Price-join (free, instant, no network)

Attach each surviving candidate's standard TLD price and reputation flags. This
is a local awk join against the bootstrap caches - do it for **every**
UNREGISTERED name, before spending any rate-limited quote:

```bash
awk -F'\t' -v OFS='\t' '
  FILENAME ~ /tld-prices/ { p[$1] = $2 "\t" $3; next }
  FILENAME ~ /tld-flags/  { if ($0 !~ /^#/ && NF >= 2) f[$1] = $2; next }
  /^#/ || $1 != "UNREGISTERED" { next }
  { pr = ($3 in p) ? p[$3] : "-\t-"; print $2, pr, ($3 in f ? f[$3] : "-") }
' "$DS/data/tld-prices.tsv" "$DS/data/tld-flags.tsv" swept.tsv \
  | sort -t"$(printf '\t')" -k3,3n > priced.tsv
```

Columns: `domain, standard_registration, standard_renewal, flags`, cheapest
renewal first.

```text
shed.link	7.72	7.72	-
hut.dev	8.75	12.87	-
shed.bar	2.57	52.01	RENEWAL_TRAP
```

This step is what makes the quote budget go far: it eliminates the names whose
whole TLD is a renewal trap before you pay 11 seconds each to quote them.

### Step 4 - Quote the survivors (the only step that may say AVAILABLE)

```bash
"$DS/scripts/quote.sh" shed.link bar.link
"$DS/scripts/quote.sh" -o json -f shortlist.txt | jq -s 'map(select(.verdict=="AVAILABLE"))'
grep '^UNREGISTERED' swept.tsv | "$DS/scripts/quote.sh" --probe never -
"$DS/scripts/check.sh" -q shed.link | "$DS/scripts/quote.sh" -o json -
```

`quote.sh` understands bare names, `check.sh` rows and `sweep.sh` rows as-is.

```text
# prices are USD per year; RATIO = quoted renewal / list renewal
DOMAIN        VERDICT      QUOTE-REG  QUOTE-REN  LIST-REG  LIST-REN    RATIO  NOTES
shed.link     PREMIUM         819.27     819.27      7.72      7.72   106.1x  API_PREMIUM PRICE_OVER_LIST
hut.dev       AVAILABLE         8.75      12.87      8.75     12.87     1.0x  FIRST_YEAR_PROMO
```

**Budget carefully.** Porkbun allows roughly one check per 10 seconds per
account, so `quote.sh` waits 11s between calls: 10 names is ~2 minutes, 100
names is ~18 minutes. Quote a **shortlist**, typically 10-20 names, chosen by
you after step 3. Tell the user the expected wall-clock time before starting a
long run. Do not lower `--delay` below the account's real limit; you will just
be throttled.

For a long list, `--probe always` is cheaper: it probes first and reports
already-REGISTERED names without spending a quote on them.

### Step 5 - Present ranked results

Rank by, in order: verdict (AVAILABLE first), **renewal** price, reputation
flags, then your own judgement about the name (length, sayability, spelling from
speech). Show, for every row: verdict, renewal price, and the evidence that
produced it.

State plainly which names were quoted and which were only probed. If quotes were
not configured, say so in the summary, not in a footnote.

## Reporting rules

- **Report renewal price, not first-year price.** Registration price is a
  marketing number; renewal is what the user actually pays every year. Known
  traps, all real: `.bar` $2.57 -> **$52.01** (20x), `.codes` $4.63 ->
  **$57.16** (12x), `.fun` / `.works` / `.zone` -> **$31.41**, `.online` /
  `.site` / `.space` ~$2 -> **$26-29**, `.lol` / `.live` / `.rest` ->
  **$26.26**. Where registration and renewal differ, show both and lead with
  renewal.
- **Surface reputation flags** whenever they are set. They come back from
  `check.sh`, `quote.sh` and the price-join:
  - `SPAM_ASSOCIATED` - some corporate mail and web filters block the whole TLD.
    The $5.64 cluster (`bid date download loan men party stream trade win`) plus
    `top`, `click`, `quest`. Flag this loudly for anything that will send email
    or be shared inside a company.
  - `RENEWAL_TRAP` - renewal >= 3x registration and >= $20.
  - `RENEWAL_EXPENSIVE` - renewal >= $25/yr.
  - `NO_PREMIUM_REGISTRY` - `com`, `net` (Verisign), `uk` (Nominet), `org`. The
    list price is the real price for every name; there is no premium tier to be
    ambushed by.
  - `NO_PRICE_DATA` - the TLD is absent from the price cache. Say "unknown",
    never estimate.
  - From a quote: `API_PREMIUM`, `PRICE_OVER_LIST`, `FIRST_YEAR_PROMO`,
    `MIN_DURATION=N`.
- Quote the multi-year cost when a TLD is expensive or has `MIN_DURATION`. "$52
  a year, forever" lands very differently from "$2.57".
- Prices are USD, from Porkbun. Say so. Other registrars differ.

## Registry routing gotchas (already encoded - do not re-derive)

These were learned the hard way and are baked into `lib.sh`, `data/` and
`sweep.sh`. Do not reimplement them, do not "optimise" around them, and do not
write ad-hoc `curl` calls to RDAP endpoints in place of the scripts.

1. **Resolve every TLD's RDAP endpoint from the IANA bootstrap**
   (<https://data.iana.org/rdap/dns.json>) and cache it. `bootstrap.sh` does this.
2. **Never use the `rdap.org` proxy.** It returns HTTP 429 after roughly 60
   requests. `lib.sh` actively refuses it even if it appears in a bootstrap file.
   Always call the registry's own endpoint.
3. **Google Registry TLDs** (`app dev foo how day soy page new zip mov meme ing
   boo esq prof phd rsvp channel nexus`) route to
   `https://pubapi.registry.google/rdap`. The bootstrap endpoint for these
   throttles hard; pubapi is generous.
4. **Identity Digital / Afilias / Donuts TLDs** (`info pro rocks fyi` and ~240
   more, detected by endpoint hostname) throttle brutally - 87 lookups once sat
   unanswered for 10 minutes. They stay on **RDAP** and get 1 concurrency slot.
   Do NOT divert them to whois: these gTLDs are RDAP-only. ICANN sunset the
   WHOIS requirement, so IANA returns an empty `whois:` line for them and a
   whois fallback can only ever produce `ERROR` (regression: `betalab.fyi`).
5. **TLDs with no usable RDAP** (`io co me sh gg im st us eu de ch li at es se
   dk ie nz`) go straight to whois. Whois servers are resolved via
   `whois -h whois.iana.org <tld>` and cached. **`.co` is `whois.registry.co`,
   not `whois.nic.co`** - the single most common wrong guess.
6. **Nominet (`.uk`) is RDAP-first** at `rdap.nominet.uk`. Its whois fallback
   (`whois.nic.uk`) has its own output format: "No match for" = available,
   "Registered on:" = taken.
7. **HTTP 429 / 000 / 503 get exponential backoff and a retry queue**, then a
   final-round fallback from RDAP to whois. A throttled endpoint is never
   allowed to be the last word on a name.
8. **Never use DNS/NS lookups as an availability pre-filter.** Measured
   false-positive rate ~90%: parked and registered domains frequently have no NS
   records. All 30 "candidate" 3-letter `.uk` names found that way turned out to
   be registered. `dig` tells you nothing about registration.

### Reading a short-name sweep

High apparent availability at short lengths is a **premium-pricing signal, not
an opportunity**. 633 of the 676 two-letter `.foo` names probe as unregistered -
they are registry-reserved. By contrast **all 676** two-letter `.uk` names are
registered, precisely because Nominet has no premium tier, so investors could
sweep them at list price. Interpret a wall of UNREGISTERED short names as "this
registry is holding stock back", and say so to the user.

## Failure modes

| Symptom                                | What it means                     | Do this                                                                 |
| -------------------------------------- | --------------------------------- | ----------------------------------------------------------------------- |
| ERROR rows in a sweep                  | no answer, not a "probably free"  | re-run those names; report them as unknown                              |
| `rdap:429` / `rate-limited`            | registry is throttling            | let the retry rounds run; lower `-p`; never bypass with raw curl        |
| A sweep crawls                         | one angry registry owns the clock | `--dry-run` and `--explain-limit` to see which; it is usually by design  |
| `no price data` / `NO_PRICE_DATA`      | TLD absent from Porkbun's list    | say "unknown"; do not estimate                                          |
| `quote.sh` exits 3                     | no credentials                    | explain the export; keep reporting UNREGISTERED, not AVAILABLE          |
| `quote.sh` exits 4                     | API rejected the key or the IP    | stop; check the key and its IP restriction. Do not retry in a loop      |
| Bootstrap verification fails           | truncated download / captive proxy| `bootstrap.sh --force`; caches below the sanity floor are not trusted   |

Exit codes: `check.sh` 0 ok / 1 some ERROR / 2 usage. `sweep.sh` 0 ok / 1 fatal
/ 2 some ERROR / 130 interrupted (partial results still written). `quote.sh` 0
ok / 1 some ERROR / 2 usage / 3 no credentials / 4 API rejected.

## Script reference

| Script         | Network | Purpose                                                                 |
| -------------- | ------- | ----------------------------------------------------------------------- |
| `bootstrap.sh` | yes     | refresh `data/` caches: RDAP endpoints, prices, whois servers, flags     |
| `generate.sh`  | no      | mechanical candidate expansion: words, cvc, cvcv, two, compound, affix   |
| `check.sh`     | yes     | a few names, precisely: status + standard price + flags                  |
| `sweep.sh`     | yes     | thousands of names: registry-grouped, rate-limit-aware, retrying         |
| `quote.sh`     | yes     | authenticated per-name quote; the only source of AVAILABLE/PREMIUM       |

Every script supports `--help`. Read it rather than guessing at a flag.

Useful environment variables: `DS_DATA_DIR`, `DS_QUIET`, `DS_DEBUG`,
`DS_SWEEP_PARALLEL`, `DS_SWEEP_ROUNDS`, `DS_QUOTE_DELAY`,
`DS_QUOTE_PREMIUM_MULTIPLE`, `PORKBUN_API_KEY`, `PORKBUN_SECRET_KEY`.

## Recipes

**"Is `example.com` free?"**

```bash
"$DS/scripts/check.sh" example.com          # then quote.sh if UNREGISTERED
```

**"Find me a short wrapper domain for my side projects."**
Brainstorm labels yourself -> `generate.sh --words -` across 3-6 plausible TLDs
-> `sweep.sh` -> price-join -> quote the best 10-15 -> rank by renewal price and
sayability. Recommend `NO_PREMIUM_REGISTRY` TLDs when the user wants no
surprises.

**"Which TLD should I use / what does .io cost?"**

```bash
awk -F'\t' '$1 == "io" || $1 == "dev" || $1 == "com" { print }' "$DS/data/tld-prices.tsv"
```

Then report renewal, plus flags from `data/tld-flags.tsv`. Never answer this
from memory - the price table is cached locally and is authoritative here.

**"Audit what I'm paying for my domains."**
Take the user's list -> `check.sh --json` for status and standard prices ->
highlight `RENEWAL_TRAP` / `RENEWAL_EXPENSIVE` / `SPAM_ASSOCIATED` -> compute
annual spend at **renewal** prices -> suggest cheaper equivalents and check
those are actually purchasable before recommending them.

**"Get me a 3-letter domain."**

```bash
"$DS/scripts/generate.sh" --cvc --tld dev --count      # 1615 - confirm with the user
"$DS/scripts/generate.sh" --cvc --tld dev > c.txt
"$DS/scripts/sweep.sh" --dry-run c.txt && "$DS/scripts/sweep.sh" -o swept.tsv c.txt
```

Expect most UNREGISTERED hits at this length to be premium or reserved. Say so
before the user gets attached to one.

## Checklist before answering

- [ ] Did a script produce every status and every price in this answer?
- [ ] Is the word "available" used only for names `quote.sh` verdicted AVAILABLE?
- [ ] Are ERROR rows reported as unknown rather than omitted?
- [ ] Is the price shown the **renewal** price?
- [ ] Are `SPAM_ASSOCIATED` / `RENEWAL_TRAP` flags surfaced, not buried?
- [ ] If quotes were unavailable, does the summary say results are unverified?

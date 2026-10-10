---
name: dd-quick-order
description: >-
  Place a single one-off DoorDash order dropped mid-conversation into any
  agent surface (terminal, Slack, Claude, Codex, Grok, etc.) using dd-cli /
  the DoorDash MCP — e.g. "nice work on that refactor, now order me a 10
  piece chicken nuggets, extra ketchup on the side."
---

# Quick order (ad-hoc, mid-session)

Use this when someone drops a casual, one-off food request into whatever
they're already doing with their agent — it isn't a recurring automation and
isn't a group order, just "get me this, now."

> "Hey, great job refactoring my codebase — now please order me a 10 piece
> chicken nuggets. Remember extra ketchup on the side."

## Flow

### 1. Sign-in check

If this is the first DoorDash command of the session and it fails with an
authentication error, run `dd-cli login` (opens a browser) and retry — don't
assume the tool is broken. In a headless agent surface with no browser
available to the end user, tell them to run `dd-cli login` themselves (or set
`DD_CLI_ACCESS_TOKEN` from `dd-cli export-token` run elsewhere) and retry.

### 2. Check for an existing open cart at the target store first

A consumer can only have one open cart per store:

```
dd-cli cart list --store-id <id> --intent "..."
```

If there's a stale cart from earlier, surface it and ask whether to extend
it or start fresh (`dd-cli cart delete --cart-uuid <id>`).

### 3. Find the store and build the cart

Get `<default_address_id>` from `dd-cli --json-output address list --intent
"..."` (see the output note under Guardrails — an account can have many saved
addresses). The address marked as default isn't necessarily where the person
is today: if it isn't labelled Home or Work, confirm it with them in one
sentence before searching.

```
dd-cli search -q "chicken nuggets" --address-id <default_address_id> --limit 5 --intent "..."
dd-cli menu --store-id <store_id> --intent "..."
```

Pick the specific item (e.g. "10 Piece Chicken Nuggets") from the menu
response's `item_id`, and check whether it has a required-options group for
sides/sauces before adding — if "extra ketchup" maps to a modifier option in
`nested_options`, include it there rather than as free text (free text on an
item name is not passed to the kitchen).

```
dd-cli cart add-items --store-id <store_id> --menu-id <menu_id> \
  --items-json '[{"item_id":"<id>","item_name":"10 Piece Chicken Nuggets","quantity":1,
    "nested_options":[{"id":"<ketchup_option_id>","name":"Extra Ketchup","quantity":1}]}]' \
  --intent "..."
```

If ketchup isn't a selectable modifier on this item, say so plainly rather
than silently dropping the request — don't fabricate a modifier ID.

### 4. Preview, confirm, submit

```
dd-cli order preview --cart-uuid <cart_uuid> --intent "..."
```

Show the priced cart and ask for explicit confirmation, including the tip
(required disclosure before submit — see below) and which payment method
will be charged:

```
dd-cli payment-method list --intent "..."
```

Name the card (brand + last4) that matches `default_payment_method_id`
before asking "should I place this on your Visa ending 3626?" On explicit
yes:

```
dd-cli order submit --cart-uuid <cart_uuid> --tip-cents <n> --yes --intent "..."
```

`--yes` is required in a non-interactive agent context, but it does **not**
replace the confirmation step above — get the human's explicit go-ahead in
chat before running submit, every time. This command charges a real card
immediately; there's no "undo."

### 5. Confirm placement

```
dd-cli order status --order-uuid <order_uuid> --intent "..."
```

Report back once it clears `pending` (or after a couple of short polls) —
don't declare success straight off `submit`'s return.

## Guardrails specific to quick, casual requests

- **Casual phrasing still needs the same confirmation discipline** as any
  order — "now order me nuggets" is not itself consent to charge a card; get
  an explicit yes on the priced preview first.
- **Don't over-fetch.** For a single obvious item, one `search` +
  one `menu` call is normally enough — no need to explore multiple
  restaurants unless the request is ambiguous ("get me some nuggets" with no
  restaurant named and multiple nearby options). If answering would take
  cart-by-cart probing across more than a few stores, or the CLI can't
  express the constraint (a delivery-by time, dietary needs, a price cap),
  stop: report the candidates you have, say what you couldn't check, and ask
  before continuing.
- **Keep large output out of the conversation.** `menu` responses (and an
  `address list` with many entries) can be very large. Write
  `--json-output` results to a scratch file, look at the shape first
  (`jq 'keys' file.json` — on success the result is wrapped in an envelope
  and the parsed payload is under `structuredContent`; a failed call exits
  non-zero and writes its error to stderr, leaving the file empty), then
  pull out only the fields you need — never print a full menu or address
  book into the chat.
- **Age-restricted items** (alcohol, etc.) can't complete through agentic
  checkout — if `order submit` returns
  `error_reason=AGENTIC_RESTRICTED_ITEM_NOT_ALLOWED`, tell the person and
  hand them `dd-cli order checkout-url --cart-uuid <id> --intent "..."` to
  finish in a browser.
- **If the request is genuinely one-off**, don't set up a recurring
  automation for it — that's `dd-lunch-autopilot`, a different skill for a
  different kind of ask.

# terraform-aws-rds-burstable-alarms

Alarms for a burstable RDS instance, from a db.t4g.micro to a db.t3.2xlarge. The module watches how fast a burst balance is falling, and warns before RDS restarts the instance.

## Why

A burstable RDS instance gets a small steady share of CPU and EBS throughput, and a balance to spend when it needs more. Work that stays above the share drains the balance. When the EBS balance is spent, the instance is held to its share, and RDS can restart it. RDS calls that restart a recovery. A larger burstable class has a larger share, and the rule does not change.

RDS restarted a db.t4g.micro this way while it ran a shared Postgres for several apps. These are its hourly values. The restart came at the end of the 08:00 hour:

| Hour | EBS byte balance, low | CPU credits, low | Free memory, low | Swap, high | Connections, high |
|---|---|---|---|---|---|
| 05:00 | 62% | 288 | 35 MB | 219 MB | 52 |
| 06:00 | 49% | 282 | 33 MB | 254 MB | 60 |
| 07:00 | 31% | 283 | 30 MB | 300 MB | 58 |
| 08:00 | 2% | 280 | 30 MB | 337 MB | 57 |
| 09:00 | 97% | 0 | 99 MB | 152 MB | 36 |

Three usual alarms gave no warning or a late one. CPU credits stayed near their 288 maximum until the restart, which set them to 0. Connections stayed under 80% of a `max_connections` of 79. A flat alarm at 20% of the EBS balance was late: the balance was at 31% or more until the hour of the restart.

The rate was already high at 06:00: the EBS balance was losing 13 points an hour, and swap was growing. RDS restarted that instance again the next day under a different workload. Two replays of those days on restored copies ended in a restart too. In all four the EBS byte balance fell to 2% or less before the restart.

The restart never appears as a metric. It is an RDS event in the `recovery` category, and you see it only if you subscribe to it.

## Usage

```hcl
module "db_alarms" {
  source  = "fizz/rds-burstable-alarms/aws"
  version = "~> 0.2.0"

  db_instance_identifier = "app-db"
  alarm_emails           = ["ops@example.com"]

  # Optional. Read it from the database: SHOW max_connections;
  max_connections = 79
}
```

Each address gets a confirmation email from AWS. Until someone clicks it, the address receives nothing. To use a topic you already have (for example, one wired to Slack through AWS Chatbot), pass `alarm_topic_arn` instead of `alarm_emails`.

## The alarms

| Alarm | Fires when | Default |
|---|---|---|
| `<balance>-240m`, `<balance>-60m`, `<balance>-20m` | the balance will be at 1% of full or less in that many minutes at its present rate, or is now | `minutes_of_warning = [240, 60, 20]` |
| `<balance>-empty` | the balance is at 1% of full or less | |
| `ebs-falls-while-swap-grows` | in one hour the EBS byte balance falls more than 10 points and swap grows more than 25 MB | |
| `freeable-memory` | free memory stays below a percent of the class's memory | 10%, about 100 MB on 1 GiB |
| `swap-usage` | swap is growing while free memory is below that percent | 10% |
| `connections` | connections are above a percent of `max_connections`, and only if you give it | 70% |
| RDS events | `failure`, `recovery`, `low storage`, `failover` | |

The balances are `ebs-byte-balance` and `ebs-io-balance`, `cpu-credit-balance` on t3 and t4g, and `storage-burst-balance` on a gp2 volume. With the defaults, a t3 or t4g instance has 15 metric alarms on gp3 and 19 on gp2, and one more if you give `max_connections`.

A metric alarm must breach for 5 minutes in a row (`evaluation_minutes`). The module rounds that up to a whole number of the alarm's periods, with a minimum of one:

| Period | Alarms | Reason |
|---|---|---|
| 1 minute | `freeable-memory`, `connections` | the metrics publish each minute |
| 5 minutes | the balance alarms up to 60 minutes of warning, `-empty`, `swap-usage` | the balances publish one datapoint every 5 minutes, and swap has to grow over 5 minutes |
| 1 hour | the balance alarms over 60 minutes of warning, `ebs-falls-while-swap-grows` | one 5-minute change projected that far is noise |

So 7 minutes is 7 one-minute periods, two 5-minute periods, or one hour. Low-side alarms use the minimum of each period and high-side alarms the maximum, so a short dip is not averaged away. The swap alarm uses the maximum of free memory, so memory has to be low for the whole 5 minutes. Missing data does not breach, because a class may not report every metric.

### The first apply

A new alarm moves from no data to OK, and that sends a notification for each alarm. To avoid it, apply with `actions_enabled = false`, wait until every alarm has a state, and apply again with `true`. No alarm changes state in the second apply, so it sends nothing. `actions_enabled` does not change RDS events.

## Minutes of warning

A balance at 20% is fine if it is steady and an emergency if it was 60% ten minutes ago. So a balance alarm looks at where the balance is going. It projects the balance `minutes_of_warning` ahead, and fires when the projection is at or below 1% of full:

```
balance + RATE(balance) * minutes * 60
```

`RATE` is per second, between the last two datapoints. 1% of full is 1 for the percent balances, and for CPU credits it follows the class: 2.88 on a micro, which can bank 288. `minutes_of_warning` is a list, with one alarm on each balance for each number:

- **Up to 60 minutes** the rate is between two 5-minute datapoints. From full, a percent balance fires at 20 minutes on a drop of 20 points in 5 minutes, and at 60 minutes on 8.
- **Over 60 minutes** the rate is between the lows of two hours, so the alarm can fire only after the hour's point is in. From full, it fires at 240 minutes on a drop of 20 points in an hour, and at 1440, the most you can give, on 4.

In the table at the top, the 240-minute condition is true for the 06:00 hour (49 points, less 13 an hour for 4 hours). That hour's point is in at 07:00, about two hours before the restart. This is arithmetic on the recorded values. These alarms did not exist then.

How a balance alarm reads the balance:

- **Falling:** fires when the balance will reach 1% within the warning.
- **Flat:** the projection is the balance itself, so it is quiet above 1% and fires at 1% or below.
- **Rising:** quiet above 1%. At 1% or below it stays quiet only if it will pass 1% within the warning.
- **No rate yet:** the projection is the balance itself, so a spent balance still fires.

An instance that starts from 0 credits fires its CPU credit alarms until it earns more than 1%. The restarts above set the balance to 0, so an instance that RDS just restarted does this too. An idle burstable instance earns 1% of what it can bank in 14.4 minutes, whatever its size. A busy one takes longer. The 240-minute alarm can stay on until the second hourly point.

The alarm fires once the projection has been low for `evaluation_minutes`, so the real warning is shorter by as much, and a warning close to `evaluation_minutes` gives none.

### Two resources at once

`ebs-falls-while-swap-grows` watches for an instance that is losing more than one resource. Its limits, 10 points and 25 MB in an hour, come from the two restarts on one db.t4g.micro. On that instance the condition was true in 8 of 1,656 hours: 5 on the two days with a restart, and 3 on three other days.

### What is measured, and what is not

The expressions were run with `GetMetricData` against a db.t3.medium with a gp3 volume. A metric the instance never reported gave no points. A metric that was missing in 4 of 5 periods gave only its real points. A range of one period, where `RATE` has no value, gave the balance. In the swap alarm's `IF`, a comparison on a metric that was never reported counted as false, and one on a metric missing in 4 of 5 periods was true only where it had a point.

All 15 alarms run on that instance, and each one reached OK on a real datapoint, including the hourly ones. None of them has fired yet. AWS documents that an alarm on `RATE` can behave unpredictably on sparse data, because the range of datapoints it fetches can vary with when they were last published. That covers `swap-usage`, `ebs-falls-while-swap-grows` and every balance alarm except `-empty`, which has no `RATE`.

## Thresholds follow the class

The module reads the instance's class and storage type from RDS and the class's memory from EC2, so the memory floor, the swap alarm's floor and the point where CPU credits are spent are computed, not typed in. Move the instance from a micro to a small and the next apply doubles all three. A threshold sized for the old class cannot stay behind and fire every night. Move the volume from gp2 to gp3 and the next apply removes the gp2 alarms.

`max_connections` is the one value you must give yourself. The default parameter group sets it from memory that RDS keeps for its own use, and that amount is not published. On a db.t4g.micro it comes out at 79. Read it with `SHOW max_connections;` instead of computing it.

## What this module does not do

It does not limit connections. A per-role `CONNECTION LIMIT` looks like a safety net, but it stays on the role after the code that set it is gone. Then it refuses connections the day the instance grows and someone raises the app's pool. Size the application's pools instead, and let these alarms tell you when the instance is too small for them.

## Requirements

Terraform 1.7 or later and the AWS provider 6.0 or later. The tests run with a mocked provider and need no credentials:

```sh
terraform init -backend=false
terraform test
```

## Changes in 0.2.0

This release is breaking. A version constraint of `~> 0.1` accepts it. Use `~> 0.1.1` to stay on 0.1.

In 0.1 the balance alarms fired below a flat percent and the swap alarm above a flat size. A steady balance under 20% paged although it was not running out. A fast drain from 100% did not page until it was under 20%. A host that held 300 MiB of swap with gigabytes free stayed in alarm. The balance alarms now fire on where the balance is going, at several times before it is spent and again when it is. The swap alarm fires on growing swap with low memory. `ebs-falls-while-swap-grows` is new.

**Inputs.** `cpu_credit_percent`, `burst_balance_percent` and `swap_usage_bytes` are removed. `minutes_of_warning` and `actions_enabled` are new. A caller that sets a removed input gets `An argument named "..." is not expected here` from `terraform init`, before anything changes. A percent does not convert to minutes, so no value moves over: delete the three arguments, and set `minutes_of_warning` if `[240, 60, 20]` does not suit. The swap alarm has no input of its own and uses `freeable_memory_percent`.

**Alarm names.** `cpu-credit-balance`, `ebs-byte-balance`, `ebs-io-balance` and `storage-burst-balance` are destroyed. Each balance the instance has gets `-240m`, `-60m`, `-20m` and `-empty` alarms in their place, so anything that refers to the old names must change. `swap-usage` changes in place. `storage-burst-balance` alarms exist only on a gp2 volume. `actions_enabled = false` on the first apply keeps the new alarms from notifying. It also silences the alarms that stay, until you set it back.

**Outputs.** `alarm_names` and `thresholds` have the new keys. In `thresholds`, a balance alarm is 1% of full in the metric's own unit (1, or 2.88 credits on a micro), and `swap-usage` and `ebs-falls-while-swap-grows` are 1.

## Changes in 0.1.1

In 0.1.0 every alarm used a 60-second period, so `CPUCreditBalance`, `EBSByteBalance%` and `EBSIOBalance%`, which report every 5 minutes, had four empty periods in five. Empty periods count as healthy, so those three alarms could miss a real breach. They now use a 5-minute period, and so does `BurstBalance`. Inputs, outputs, alarm names and thresholds are the same, and an upgrade is an in-place change to those four alarms.

## License

MIT

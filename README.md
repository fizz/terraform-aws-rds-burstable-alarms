# terraform-aws-rds-burstable-alarms

Alarms for a burstable RDS instance, from a db.t4g.micro to a db.t3.2xlarge. The module watches the signals that come before a forced restart, not the ones that come after.

## Why

A db.t4g.micro running a shared Postgres for several apps restarted with no warning. RDS called it a recovery: the instance ran out of memory and RDS rebooted it. Every app on it was down for four minutes.

It had 47 connections open. Its `max_connections` was 79. A connections alarm set at 80% would never have fired, because memory ran out first. Each Postgres connection is its own process and holds its own memory, and a 1 GiB instance has very little left after shared buffers and the operating system take their part.

The signs were all there, in metrics nobody watched:

| Signal | Before the restart |
|---|---|
| `FreeableMemory` | below about 110 MB |
| `SwapUsage` | above 300 MB |
| `EBSByteBalance%` | falling to 0, because swap is disk I/O |
| `CPUCreditBalance` | draining at the same time |

The restart itself never appears as a metric. It is an RDS event in the `recovery` category, and you see it only if you subscribe to it.

This module alarms on all of them.

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
| `freeable-memory` | free memory stays below a percent of the class's memory | 10%, about 100 MB on 1 GiB |
| `swap-usage` | swap is growing while free memory is below the same percent | 10% |
| `cpu-credit-balance` | t3 and t4g only: CPU credits will be spent soon at their present rate, or are spent now | 20 minutes |
| `ebs-byte-balance`, `ebs-io-balance` | the instance's EBS burst will be spent soon at its present rate, or is spent now | 20 minutes |
| `storage-burst-balance` | gp2 volumes only: the volume's burst will be spent soon at its present rate, or is spent now | 20 minutes |
| `connections` | only if you give `max_connections` | 70% of it |
| RDS events | `failure`, `recovery`, `low storage`, `failover` | |

Every metric alarm must breach for 5 minutes in a row (`evaluation_minutes`). The credit and burst balance alarms use a 5-minute period, because `CPUCreditBalance`, `EBSByteBalance%` and `EBSIOBalance%` publish one datapoint every 5 minutes. The swap alarm uses a 5-minute period too, so that swap has to grow over 5 minutes instead of in each single minute. The other alarms use a 1-minute period. `evaluation_minutes` is rounded up to a whole number of periods, with a minimum of one: 7 minutes is 7 one-minute periods, or two 5-minute periods (10 minutes) on the balance and swap alarms, and a value below 5 is one 5-minute period on those. Low-side alarms use the minimum of each period and high-side alarms the maximum, so a short dip is not averaged away. The swap alarm uses the maximum of free memory, so memory has to be low for the whole 5 minutes. Missing data does not breach, because a class may not report every metric. The `storage-burst-balance` alarm exists only on a gp2 volume.

## Minutes of warning

A balance at 20% is fine if it is steady and an emergency if it was 60% ten minutes ago. So a balance alarm looks at where the balance is going. It projects the balance `minutes_of_warning` ahead (default 20) at the rate between its last two datapoints, and fires when the projection is at or below 1% of full:

```
balance + RATE(balance) * minutes_of_warning * 60
```

`RATE` is per second. 1% of full is 1 for the percent balances, and for CPU credits it follows the class: 2.88 on a micro, which can bank 288.

- **Falling:** fires when the balance will reach 1% within the warning.
- **Flat:** the projection is the balance itself, so it is quiet above 1% and fires at 1% or below.
- **Rising:** quiet above 1%. At 1% or below it stays quiet only if it will pass 1% within the warning.
- **No rate yet:** the projection is the balance itself, so a spent balance still fires.

An idle burstable instance earns 1% of what it can bank in 14.4 minutes, whatever its size. If it starts from 0 credits, its first datapoint has no rate and breaches at any warning. After that, with a warning of 10 minutes or more its projection is above 1% from the second datapoint, and with a shorter one it breaches until 14.4 minutes minus the warning have passed. A busy instance keeps only part of what it earns and can breach for longer: at 20 minutes, one that keeps 57% or less still breaches on its second datapoint.

The alarm fires once the projection has been low for `evaluation_minutes`, so the real warning is shorter by as much, and a `minutes_of_warning` close to `evaluation_minutes` gives none.

A longer warning is also louder, because it carries one 5-minute change further. From full, a percent balance fires at 20 minutes on a drop of 20 points in one period, at 30 minutes on 15, and at 60 minutes on 8. At 490 minutes a drop of one point is enough, and `EBSByteBalance%` was measured dropping one point in a period on an instance that stayed between 99 and 100. `minutes_of_warning` is at most 1440, one day.

### What is measured, and what is not

The expression was run with `GetMetricData` against a db.t3.medium with a gp3 volume. A metric the instance never reported gave no points. A metric that was missing in 4 of 5 periods gave only its real points. A range of one period, where `RATE` has no value, gave the balance. In the swap alarm's `IF`, a comparison on a metric that was never reported counted as false, and one on a metric missing in 4 of 5 periods was true only where it had a point.

No live alarm has been seen evaluating these expressions yet. AWS documents that an alarm on `RATE` can behave unpredictably on sparse data, because the range of datapoints it fetches can vary with when they were last published. That covers the balance alarms and the swap alarm.

## Thresholds follow the class

The module reads the instance's class and storage type from RDS and the class's memory from EC2, so the memory floor, the swap alarm's floor and the point where CPU credits are spent are computed, not typed in. Move the instance from a micro to a small and the next apply doubles all three. A threshold sized for the old class cannot stay behind and fire every night. Move the volume from gp2 to gp3 and the next apply removes the gp2 alarm.

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

This release is breaking. A version constraint of `~> 0.1` accepts it; use `~> 0.1.1` to stay on 0.1.

In 0.1 the balance alarms fired below a flat percent and the swap alarm above a flat size. A steady balance under 20% paged although it was not running out, a fast drain from 100% did not page until it was under 20%, and a host that held 300 MiB of swap with gigabytes free stayed in alarm. The balance alarms now fire on where the balance is going, and the swap alarm on growing swap with low memory.

`cpu_credit_percent`, `burst_balance_percent` and `swap_usage_bytes` are removed, and `minutes_of_warning` is new. A caller that sets a removed input gets `An argument named "..." is not expected here` from `terraform init`, before anything changes. A percent does not convert to minutes, so no value carries over: delete the three arguments, and set `minutes_of_warning` if 20 does not suit. The swap alarm has no input of its own and uses `freeable_memory_percent`.

Alarm names are the same. An upgrade is an in-place change to `cpu-credit-balance`, `ebs-byte-balance`, `ebs-io-balance`, `storage-burst-balance` and `swap-usage`. On a volume that is not gp2, `storage-burst-balance` is destroyed and leaves the `alarm_names` and `thresholds` outputs. In `thresholds`, a balance alarm is now 1% of full in the metric's own unit (1, or 2.88 credits on a micro), and `swap-usage` is 1.

## Changes in 0.1.1

In 0.1.0 every alarm used a 60-second period, so `CPUCreditBalance`, `EBSByteBalance%` and `EBSIOBalance%`, which report every 5 minutes, had four empty periods in five. Empty periods count as healthy, so those three alarms could miss a real breach. They now use a 5-minute period, and so does `BurstBalance`. Inputs, outputs, alarm names and thresholds are the same, and an upgrade is an in-place change to those four alarms.

## License

MIT

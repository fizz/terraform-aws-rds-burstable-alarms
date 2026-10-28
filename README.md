# terraform-aws-rds-burstable-alarms

Alarms for the small RDS instance that is about to fall over. Point it at a db.t4g.micro or any other class, and it watches the signals that come before a forced restart, not the ones that come after.

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
  version = "~> 0.1"

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
| `swap-usage` | swap goes above a size | 256 MiB |
| `cpu-credit-balance` | t3 and t4g only: CPU credits fall below a percent of what the class can bank | 20% |
| `ebs-byte-balance`, `ebs-io-balance` | the instance's EBS burst is nearly spent | 20% |
| `storage-burst-balance` | a gp2 volume's burst is nearly spent | 20% |
| `connections` | only if you give `max_connections` | 70% of it |
| RDS events | `failure`, `recovery`, `low storage`, `failover` | |

Every metric alarm must breach for 5 minutes in a row (`evaluation_minutes`). Low-side alarms use the minimum of each minute and high-side alarms the maximum, so a short dip is not averaged away. A metric that the class or volume does not report counts as fine: a gp3 volume has no `BurstBalance`, and it never pages anyone.

## Thresholds follow the class

The module reads the instance's class from RDS and the class's memory from EC2, so the memory and CPU credit thresholds are computed, not typed in. Move the instance from a micro to a small and the next apply doubles the memory threshold. A threshold sized for the old class cannot stay behind and fire every night.

`max_connections` is the one value you must give yourself. The default parameter group sets it from memory that RDS keeps for its own use, and that amount is not published. On a db.t4g.micro it comes out at 79. Read it with `SHOW max_connections;` instead of computing it.

## What this module does not do

It does not limit connections. A per-role `CONNECTION LIMIT` looks like a safety net, but it stays on the role after the code that set it is gone. Then it refuses connections the day the instance grows and someone raises the app's pool. Size the application's pools instead, and let these alarms tell you when the instance is too small for them.

## Requirements

Terraform 1.7 or later and the AWS provider 6.0 or later. The tests run with a mocked provider and need no credentials:

```sh
terraform init -backend=false
terraform test
```

## License

MIT

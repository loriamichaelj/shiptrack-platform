"""Command line: `shiptrack-sim run` sends events; `shiptrack-sim verify` checks the ledger."""

from __future__ import annotations

import argparse
import asyncio
import os
import sys
from pathlib import Path

from .ledger import Ledger, default_ledger_path
from .plan import plan_run


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="shiptrack-sim", description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    run = commands.add_parser("run", help="create shipments and send their lifecycles")
    run.add_argument("--base-url", default=os.environ.get("BASE_URL"), help="default: $BASE_URL")
    run.add_argument(
        "--target", default=os.environ.get("TARGET", "none"), choices=["legacy", "modern", "none"]
    )
    run.add_argument("--shipments", type=int, default=100)
    run.add_argument("--concurrency", type=int, default=10)
    run.add_argument("--delay", type=float, default=0.0, help="seconds to wait between events of a shipment")
    run.add_argument("--seed", type=int, default=1, help="the same seed plans the same run")
    run.add_argument(
        "--retry-seconds",
        type=float,
        default=0.0,
        help="try a request again after a connection error or 502/503/504 for up to this long (default: 0)",
    )
    run.add_argument("--results-dir", type=Path, default=Path("results"))

    verify = commands.add_parser("verify", help="report accepted events that were never persisted")
    verify.add_argument("--ledger", type=Path, required=True)
    verify.add_argument("--db-url", default=os.environ.get("DATABASE_URL"), help="default: $DATABASE_URL")
    verify.add_argument(
        "--base-url",
        default=None,
        help=(
            "check through the API's tracking timelines instead of the database (no database access "
            "needed). The timeline lists applied events only, so out-of-order events show as missing"
        ),
    )
    verify.add_argument(
        "--target", default=os.environ.get("TARGET", "none"), choices=["legacy", "modern", "none"]
    )
    verify.add_argument(
        "--wait",
        type=float,
        default=0.0,
        help="with --base-url, keep looking for missing events this many seconds (workers apply late)",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    if args.command == "run":
        if not args.base_url:
            print("--base-url or BASE_URL is required", file=sys.stderr)
            return 2
        from .runner import run  # httpx is imported only for `run`

        plans = plan_run(args.seed, args.shipments)
        ledger_path = default_ledger_path(args.results_dir)
        with Ledger(ledger_path) as ledger:
            stats = asyncio.run(
                run(
                    plans,
                    base_url=args.base_url,
                    target=args.target,
                    token=os.environ.get("TEST_TOKEN", ""),
                    ledger=ledger,
                    concurrency=args.concurrency,
                    delay=args.delay,
                    seed=args.seed,
                    retry_seconds=args.retry_seconds,
                )
            )
        print(stats.summary())
        print(f"ledger: {ledger_path}")
        for error in sorted(set(stats.errors))[:5]:
            print(f"error: {error}", file=sys.stderr)
        return 0 if stats.shipments_failed == 0 else 1

    if args.base_url:
        from .verify import verify_ledger_api

        result = verify_ledger_api(
            args.ledger,
            args.base_url,
            target=args.target,
            token=os.environ.get("TEST_TOKEN", ""),
            wait_seconds=args.wait,
        )
    else:
        if not args.db_url:
            print("--db-url or DATABASE_URL, or --base-url, is required", file=sys.stderr)
            return 2
        from .verify import verify_ledger  # psycopg is imported only for `verify`

        result = verify_ledger(args.ledger, args.db_url)
    print(result.report())
    return 0 if result.ok else 1


if __name__ == "__main__":
    raise SystemExit(main())

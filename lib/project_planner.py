#!/usr/bin/env python3
"""
Interactive Project Planner for Tmux Orchestrator.

Guides users through project planning before deploying agents.
"""

import json
import os
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Tuple


class ProjectPlanner:
    """Interactive project planning workflow."""

    def __init__(self, project_path: str):
        self.project_path = Path(project_path).expanduser().resolve()
        self.project_name = self.project_path.name
        self.answers: Dict[str, str] = {}
        self.prd: Dict = {}
        self.team_config: List[Dict] = []

    def run_interactive(self) -> Tuple[str, str]:
        """
        Run the full interactive planning workflow.

        Returns:
            Tuple of (prd_path, team_config_path)
        """
        print("\n" + "=" * 60)
        print("  PROJECT PLANNER - Tmux Orchestrator")
        print("=" * 60)
        print(f"\nProject: {self.project_name}")
        print(f"Path: {self.project_path}\n")

        # Phase 1: Discovery
        print("-" * 40)
        print("PHASE 1: DISCOVERY")
        print("-" * 40)
        self._ask_discovery_questions()

        # Phase 2: Generate PRD
        print("\n" + "-" * 40)
        print("PHASE 2: PRD GENERATION")
        print("-" * 40)
        self._generate_prd()
        prd_path = self._save_prd()
        print(f"\n✓ PRD saved to: {prd_path}")

        # Phase 3: Propose Team
        print("\n" + "-" * 40)
        print("PHASE 3: TEAM PROPOSAL")
        print("-" * 40)
        self._propose_team()
        team_path = self._save_team_config()
        print(f"\n✓ Team config saved to: {team_path}")

        # Phase 4: Review & Approval
        print("\n" + "-" * 40)
        print("PHASE 4: REVIEW & APPROVAL")
        print("-" * 40)
        self._show_summary()

        approved = self._get_approval()

        if approved:
            print("\n✓ Plan approved! Ready to deploy.")
            print(f"\nTo deploy, run:")
            print(f"  python3 lib/orchestrator.py deploy {self.project_name} \\")
            print(f"    -p {self.project_path} \\")
            print(f"    -c {team_path} --panes")
        else:
            print("\n✗ Plan not approved. Review the files and modify as needed:")
            print(f"  PRD: {prd_path}")
            print(f"  Team: {team_path}")

        return str(prd_path), str(team_path)

    def _ask_discovery_questions(self):
        """Ask clarifying questions about the project."""

        questions = [
            ("description", "What are you building? (brief description)"),
            ("problem", "What problem does it solve?"),
            ("target_user", "Who is the target user?"),
            ("tech_stack", "Tech stack preference? (or 'suggest' for recommendation)"),
            ("platforms", "Target platforms? (web/mobile/desktop/api)"),
            ("features_v1", "Must-have features for v1? (comma-separated)"),
            ("features_nice", "Nice-to-have features? (comma-separated, or 'none')"),
            ("out_of_scope", "What's out of scope? (or 'none')"),
            ("test_coverage", "Test coverage importance? (high/medium/low)"),
            ("security", "Security considerations? (or 'standard')"),
            ("team_size", "Team size? (minimal/balanced/comprehensive)"),
            ("autonomy", "Agent autonomy? (autonomous/check-in-often)"),
        ]

        print("\nPlease answer the following questions:\n")

        for key, question in questions:
            answer = input(f"  {question}\n  > ").strip()
            self.answers[key] = answer
            print()

    def _generate_prd(self):
        """Generate PRD from answers."""

        features_v1 = [f.strip() for f in self.answers.get("features_v1", "").split(",") if f.strip()]
        features_nice = [f.strip() for f in self.answers.get("features_nice", "").split(",") if f.strip() and f.lower() != "none"]

        self.prd = {
            "project_name": self.project_name,
            "created_at": datetime.now().isoformat(),
            "overview": {
                "description": self.answers.get("description", ""),
                "problem": self.answers.get("problem", ""),
                "target_user": self.answers.get("target_user", ""),
            },
            "technical": {
                "tech_stack": self.answers.get("tech_stack", ""),
                "platforms": self.answers.get("platforms", ""),
            },
            "requirements": {
                "must_have": features_v1,
                "nice_to_have": features_nice,
                "out_of_scope": self.answers.get("out_of_scope", ""),
            },
            "quality": {
                "test_coverage": self.answers.get("test_coverage", "medium"),
                "security": self.answers.get("security", "standard"),
            }
        }

    def _save_prd(self) -> Path:
        """Save PRD to project directory."""
        prd_path = self.project_path / "PRD.json"

        with open(prd_path, "w") as f:
            json.dump(self.prd, f, indent=2)

        # Also create markdown version
        md_path = self.project_path / "prd.md"
        self._save_prd_markdown(md_path)

        return prd_path

    def _save_prd_markdown(self, path: Path):
        """Save PRD as readable markdown."""

        features_v1 = self.prd["requirements"]["must_have"]
        features_nice = self.prd["requirements"]["nice_to_have"]

        content = f"""# {self.project_name} - Product Requirements Document

Generated: {self.prd['created_at']}

## Overview

**Description**: {self.prd['overview']['description']}

**Problem**: {self.prd['overview']['problem']}

**Target User**: {self.prd['overview']['target_user']}

## Technical Requirements

- **Tech Stack**: {self.prd['technical']['tech_stack']}
- **Platforms**: {self.prd['technical']['platforms']}

## Features

### Must Have (v1)
{chr(10).join(f'- [ ] {f}' for f in features_v1) if features_v1 else '- None specified'}

### Nice to Have
{chr(10).join(f'- [ ] {f}' for f in features_nice) if features_nice else '- None specified'}

### Out of Scope
{self.prd['requirements']['out_of_scope'] or 'None specified'}

## Quality Requirements

- **Test Coverage**: {self.prd['quality']['test_coverage']}
- **Security**: {self.prd['quality']['security']}
"""

        with open(path, "w") as f:
            f.write(content)

    def _propose_team(self):
        """Propose team structure based on answers."""

        team_size = self.answers.get("team_size", "balanced").lower()
        test_coverage = self.answers.get("test_coverage", "medium").lower()
        tech_stack = self.answers.get("tech_stack", "").lower()

        # Base PM
        pm = {
            "role": "pm",
            "name": "PM",
            "focus": f"Quality oversight for {self.project_name}",
            "model": "sonnet"
        }
        self.team_config.append(pm)

        # Developer(s) based on tech stack and size
        if team_size == "minimal":
            dev = {
                "role": "developer",
                "name": "Dev",
                "focus": f"Full-stack development for {self.project_name}",
                "model": "sonnet"
            }
            self.team_config.append(dev)

        elif team_size == "balanced":
            dev = {
                "role": "developer",
                "name": "Dev",
                "focus": f"Core development for {self.project_name}",
                "model": "sonnet"
            }
            self.team_config.append(dev)

            # Add QA for balanced teams, especially with high test coverage
            if test_coverage in ["high", "medium"]:
                qa = {
                    "role": "qa",
                    "name": "QA",
                    "focus": f"Testing and quality assurance for {self.project_name}",
                    "model": "haiku"
                }
                self.team_config.append(qa)

        else:  # comprehensive
            # Multiple developers
            dev1 = {
                "role": "developer",
                "name": "Lead-Dev",
                "focus": f"Architecture and core features for {self.project_name}",
                "model": "sonnet"
            }
            self.team_config.append(dev1)

            dev2 = {
                "role": "developer",
                "name": "Dev-2",
                "focus": f"Secondary features and integration for {self.project_name}",
                "model": "sonnet"
            }
            self.team_config.append(dev2)

            # QA
            qa = {
                "role": "qa",
                "name": "QA",
                "focus": f"Comprehensive testing for {self.project_name}",
                "model": "haiku"
            }
            self.team_config.append(qa)

            # DevOps for comprehensive
            devops = {
                "role": "devops",
                "name": "DevOps",
                "focus": f"Infrastructure and deployment for {self.project_name}",
                "model": "haiku"
            }
            self.team_config.append(devops)

    def _save_team_config(self) -> Path:
        """Save team config to project directory."""
        config_path = self.project_path / "team-config.json"

        config = {
            "project": self.project_name,
            "created_at": datetime.now().isoformat(),
            "team": self.team_config
        }

        with open(config_path, "w") as f:
            json.dump(config, f, indent=2)

        return config_path

    def _show_summary(self):
        """Display summary for review."""

        print("\n" + "=" * 50)
        print("  PLAN SUMMARY")
        print("=" * 50)

        print(f"\nProject: {self.project_name}")
        print(f"Description: {self.prd['overview']['description']}")

        print(f"\nFeatures (v1):")
        for f in self.prd["requirements"]["must_have"]:
            print(f"  - {f}")

        print(f"\nProposed Team ({len(self.team_config)} agents):")
        for agent in self.team_config:
            print(f"  - {agent['name']} ({agent['role']}) - {agent['model']}")
            print(f"    Focus: {agent['focus']}")

        print("\n" + "=" * 50)

    def _get_approval(self) -> bool:
        """Get user approval."""

        print("\nReview the plan above.")
        print("You can also edit the generated files before approving:")
        print(f"  - prd.md / PRD.json")
        print(f"  - team-config.json")

        while True:
            response = input("\nApprove and continue? (yes/no/edit): ").strip().lower()

            if response in ["yes", "y"]:
                return True
            elif response in ["no", "n"]:
                return False
            elif response in ["edit", "e"]:
                print("\nEdit the files and press Enter when ready...")
                input()
                # Reload configs
                self._reload_configs()
                self._show_summary()
            else:
                print("Please answer 'yes', 'no', or 'edit'")

    def _reload_configs(self):
        """Reload configs after user edits."""
        config_path = self.project_path / "team-config.json"
        prd_path = self.project_path / "PRD.json"

        if config_path.exists():
            with open(config_path) as f:
                data = json.load(f)
                self.team_config = data.get("team", self.team_config)

        if prd_path.exists():
            with open(prd_path) as f:
                self.prd = json.load(f)


def main():
    import argparse

    parser = argparse.ArgumentParser(description="Interactive Project Planner")
    parser.add_argument("project_path", help="Path to project directory")

    args = parser.parse_args()

    # Create directory if needed
    project_path = Path(args.project_path).expanduser().resolve()
    project_path.mkdir(parents=True, exist_ok=True)

    planner = ProjectPlanner(str(project_path))
    prd_path, team_path = planner.run_interactive()

    print(f"\nGenerated files:")
    print(f"  PRD: {prd_path}")
    print(f"  Team: {team_path}")


if __name__ == "__main__":
    main()

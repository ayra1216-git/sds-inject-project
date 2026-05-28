name: deploy-installer

# WHEN to run:
#   workflow_dispatch - manual trigger from GitHub UI (you pick the target)
#   release           - auto-deploy whenever a Release is published
on:
  workflow_dispatch:
    inputs:
      target_host:
        description: "Target machine hostname or IP"
        required: true
      ssh_user:
        description: "SSH user on the target"
        required: true
        default: "vboxuser"
  release:
    types: [published]

jobs:
  deploy:
    runs-on: ubuntu-22.04

    steps:
      # 1. Check out the repo (we need cd/deploy.sh)
      - name: Checkout repo
        uses: actions/checkout@v4

      # 2. Download the installer artifact built by the CI workflow.
      #    For workflow_dispatch / release: this pulls the latest .run from
      #    the most recent successful CI run.
      - name: Download latest installer
        uses: dawidd6/action-download-artifact@v6
        with:
          workflow: ci.yml
          name: k8s-installer
          path: .
          if_no_artifact_found: fail

      # 3. Set up the SSH key so deploy.sh can connect to the target.
      #    The private key is stored as a repo secret (Settings -> Secrets).
      - name: Set up SSH key
        run: |
          mkdir -p ~/.ssh
          echo "${{ secrets.TARGET_SSH_KEY }}" > ~/.ssh/id_rsa
          chmod 600 ~/.ssh/id_rsa
          # Pre-add target host fingerprint so SSH doesn't prompt.
          ssh-keyscan -H "${{ inputs.target_host }}" >> ~/.ssh/known_hosts 2>/dev/null || true

      # 4. Run the deployment
      - name: Deploy to target
        run: |
          chmod +x cd/deploy.sh k8s-installer.run
          ./cd/deploy.sh \
            ./k8s-installer.run \
            "${{ inputs.target_host }}" \
            "${{ inputs.ssh_user }}"

      # 5. Notify on failure (GitHub also emails by default)
      - name: Notify failure
        if: failure()
        run: |
          echo "::error::CD pipeline failed for ${{ inputs.target_host }}"
          echo "Logs: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}"

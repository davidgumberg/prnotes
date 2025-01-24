repo := "bitcoin/bitcoin"

# Task to get commits from a GitHub PR and write them to a markdown file
review pr_number:
    #!/usr/bin/env bash
    set -euxo pipefail
    
    api_url="https://api.github.com/repos/{{repo}}/pulls/{{pr_number}}/commits"

    # Use curl to fetch the commit data from the GitHub API
    commits_json=$(curl -s -H "Accept: application/vnd.github+json" "$api_url")

    # Create the markdown file name
    output_file="pr_{{pr_number}}_commits.md"

    # Start the markdown list
    echo "# Commits in PR {{pr_number}}" > "${output_file}"
    echo "" >> "${output_file}"

    # Iterate through the commit messages and add them to the list
    echo "${commits_json}" | jq -c '.[]' | while read -r commit; do
        echo "* $(echo "${commit}" | jq -r '.html_url')" >> "${output_file}"
    done

    echo "Commits for PR {{pr_number}} written to ${output_file}"

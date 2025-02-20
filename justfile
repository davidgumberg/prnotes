# Watch out, tabs in here, not spaces!

repo := "bitcoin/bitcoin"

# Task to get commits from a GitHub PR and write them to a markdown file
review pr_number:
	#!/usr/bin/env bash
	set -euxo pipefail

	# save just vars as bash to avoid mixed bash/just
	repo="{{repo}}"
	pr_number="{{pr_number}}" # save as bash variable to avoid mixed bash/just

	pr_api_url="https://api.github.com/repos/{{repo}}/pulls/${pr_number}"
	pr_json=$(curl -s -H "Accept: application/vnd.github+json" "${pr_api_url}")

	commits_api_url=$(echo "${pr_json}" | jq -r '.commits_url')
	commits_json=$(curl -s -H "Accept: application/vnd.github+json" "${commits_api_url}")
	echo "${commits_json}" | jq

	pr_title=$(echo "${pr_json}" | jq -r '.title')
	pr_url=$(echo "${pr_json}" | jq -r '.html_url')

	mkdir -p $pr_number
	output_file="${pr_number}/${pr_number}.md"

	cat > $output_file <<- HEREDOC
	# [#${pr_number}](${pr_url}) ${pr_title}
	_All code comments in \`\[\]\` are my own._

	## Background

	## Problem

	## Solution

	HEREDOC

	# Iterate through the commit messages and add them to the list
	echo "${commits_json}" | jq -c '.[]' | while read -r commit; do
		commit_title=$(echo "${commit}" | jq -r '.commit.message | split("\n\n") | .[0]')
		commit_body=$(echo "${commit}" | jq -r '.commit.message | split("\n\n") | .[1]')
		commit_hash=$(echo "${commit}" | jq -r '.sha')

		# I don't believe gh api provides this special commit inside pr url
		commit_url="https://github.com/${repo}/pull/${pr_number}/commits/${commit_hash}"
		echo -e "### [${commit_title}](${commit_url})\n" >> "${output_file}"

		if [[ -n $commit_body && "${commit_body}" != "null" ]]; then
			echo "${commit_body}" | while IFS= read -r line; do
				echo "	${line}" >> "${output_file}"
			done
		fi

		echo "" >> "${output_file}"

		# another unlisted url, gets diff format of the commit
		commit_diff_url="${commit_url}.diff"
		commit_diff=$(curl -s -L "${commit_diff_url}")

		cat >> $output_file <<- HEREDOC
		<details>

		<summary>

		Commit diff
		
		</summary>

		\`\`\`diff
		HEREDOC

		echo "${commit_diff}" | while IFS= read -r line; do
			echo "${line}" >> "${output_file}"
		done
		echo -e "\`\`\`\n</details>\n" >> "${output_file}"
	done

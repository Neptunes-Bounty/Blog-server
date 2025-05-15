#!/bin/bash

USERS_YAML="/opt/blog_system/users.yaml"
ADMIN_GROUP="g_admin"
REPORT_DIR="/var/log/blog_reports"

check_admin_permission() {
    if ! id -Gn | grep -q "$ADMIN_GROUP"; then
        echo "Error: This command can only be run by an admin."
        exit 1
    fi
}

check_admin_permission

mkdir -p "$REPORT_DIR"
chown root:"$ADMIN_GROUP" "$REPORT_DIR"
chmod 770 "$REPORT_DIR"

REPORT_FILE="$REPORT_DIR/blog_report_$(date +"%Y-%m-%d_%H%M%S").txt"

echo "Generating admin report..." | tee "$REPORT_FILE"
echo "Report Date: $(date)" | tee -a "$REPORT_FILE"
echo "-----------------------------------" | tee -a "$REPORT_FILE"

echo "Blog Activity Summary (Published and Deleted by Tag):" | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"

declare -A published_counts
declare -A deleted_counts
declare -A article_tags

ALL_AUTHORS=($(yq e ".authors[].username" "$USERS_YAML"))

for author_username in "${ALL_AUTHORS[@]}"; do
    AUTHOR_BLOGS_YAML="/home/authors/$author_username/blogs.yaml"
    if [ -f "$AUTHOR_BLOGS_YAML" ]; then
        ARTICLE_KEYS=($(yq e ".articles | keys[]" "$AUTHOR_BLOGS_YAML"))

        for article_name in "${ARTICLE_KEYS[@]}"; do
            local status=$(yq e ".articles.${article_name}.publish_status" "$AUTHOR_BLOGS_YAML")
            local tags_string=$(yq e ".articles.${article_name}.tags | join(\",\")" "$AUTHOR_BLOGS_YAML" 2>/dev/null)

            local article_key="${author_username}/${article_name}"
            article_tags["$article_key"]="$tags_string"

            IFS=',' read -ra tags_array <<< "$tags_string"

            if [ "$status" == "true" ]; then
                for tag in "${tags_array[@]}"; do
                    if [ -n "$tag" ]; then
                         published_counts["$tag"]=$(( published_counts["$tag"] + 1 ))
                    fi
                done
                 if [ ${#tags_array[@]} -eq 0 ] || ([ ${#tags_array[@]} -eq 1 ] && [ -z "${tags_array[0]}" ]); then
                     published_counts["untagged"]=$(( published_counts["untagged"] + 1 ))
                 fi
            elif [ "$status" == "deleted" ]; then
                 for tag in "${tags_array[@]}"; do
                     if [ -n "$tag" ]; then
                         deleted_counts["$tag"]=$(( deleted_counts["$tag"] + 1 ))
                    fi
                 done
                 if [ ${#tags_array[@]} -eq 0 ] || ([ ${#tags_array[@]} -eq 1 ] && [ -z "${tags_array[0]}" ]); then
                     deleted_counts["untagged"]=$(( deleted_counts["untagged"] + 1 ))
                 fi
            fi
        done
    fi
done

echo "Published Articles by Tag (sorted by count):" | tee -a "$REPORT_FILE"
if [ ${#published_counts[@]} -eq 0 ]; then
    echo " None" | tee -a "$REPORT_FILE"
else
    for tag in "${!published_counts[@]}"; do
        echo "$tag: ${published_counts[$tag]}"
    done | sort -k2,2n -r | tee -a "$REPORT_FILE"
fi
echo "" | tee -a "$REPORT_FILE"

echo "Deleted Articles by Tag (sorted by count):" | tee -a "$REPORT_FILE"
if [ ${#deleted_counts[@]} -eq 0 ]; then
    echo " None" | tee -a "$REPORT_FILE"
else
    for tag in "${!deleted_counts[@]}"; do
        echo "$tag: ${deleted_counts[$tag]}"
    done | sort -k2,2n -r | tee -a "$REPORT_FILE"
fi
echo "" | tee -a "$REPORT_FILE"
echo "-----------------------------------" | tee -a "$REPORT_FILE"


echo "Top 3 Most Read Articles:" | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"

declare -A article_reads
declare -A article_titles
declare -A article_authors

for author_username in "${ALL_AUTHORS[@]}"; do
    AUTHOR_BLOGS_YAML="/home/authors/$author_username/blogs.yaml"
    if [ -f "$AUTHOR_BLOGS_YAML" ]; then
        ARTICLE_KEYS=($(yq e ".articles | keys[]" "$AUTHOR_BLOGS_YAML"))

        for article_name in "${ARTICLE_KEYS[@]}"; do
            local read_count=$(yq e ".articles.${article_name}.read_count // 0" "$AUTHOR_BLOGS_YAML")
             local title=$(yq e ".articles.${article_name}.title // \"$article_name\"" "$AUTHOR_BLOGS_YAML")
            local article_key="${author_username}/${article_name}"

            article_reads["$article_key"]="$read_count"
            article_titles["$article_key"]="$title"
            article_authors["$article_key"]="$author_username"
        done
    fi
done

if [ ${#article_reads[@]} -eq 0 ]; then
    echo " No articles with read counts available." | tee -a "$REPORT_FILE"
else
    for article_key in "${!article_reads[@]}"; do
        echo "${article_reads[$article_key]}|${article_key}"
    done | sort -t'|' -k1,1n -r | head -n 3 | while IFS='|' read -r read_count article_key; do
        local author="${article_authors[$article_key]}"
        local title="${article_titles[$article_key]}"
        local article_name=$(basename "$article_key")

        echo " - \"$title\" by $author (Reads: $read_count)" | tee -a "$REPORT_FILE"
    done
fi
echo "-----------------------------------" | tee -a "$REPORT_FILE"
echo "Report generated: $REPORT_FILE" | tee -a "$REPORT_FILE"

echo ""
echo "Cronjob Details:"
echo "Add the following line to the admin user's crontab ('crontab -e'):"
echo ""
echo "14 15 * 2,5,8,11 4,6#1,6#L /scripts/adminPanel.sh"
echo ""

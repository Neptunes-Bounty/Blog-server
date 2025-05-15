#!/bin/bash

MOD_HOME="/home/mods/$USER"
BLACKLIST_FILE="$MOD_HOME/blacklist.txt"
USERS_YAML="/opt/blog_system/users.yaml"
MOD_GROUP="g_mod"

check_mod_permission() {
    if ! id -Gn | grep -q "$MOD_GROUP"; then
        echo "Error: This command can only be run by a moderator."
        exit 1
    fi
}

generate_asterisks() {
    local len=$1
    printf '%*s' "$len" | tr ' ' '*'
}

archive_blog_by_filter() {
    local author_username="$1"
    local article_name="$2"
    local blacklist_count="$3"

    local author_public_dir="/home/authors/$author_username/public"
    local blogs_yaml="/home/authors/$author_username/blogs.yaml"

    echo "Blog $article_name by $author_username is being archived due to excessive blacklisted words ($blacklist_count instances)."

    if [ -f "$author_public_dir/${article_name}.md" ]; then
        rm "$author_public_dir/${article_name}.md"
         setfacl -b "$author_public_dir/${article_name}.md" 2>/dev/null
    fi
    local author_subs_dir="/home/authors/$author_username/subscribers_only"
    if [ -f "$author_subs_dir/${article_name}.md" ]; then
        rm "$author_subs_dir/${article_name}.md"
         setfacl -b "$author_subs_dir/${article_name}.md" 2>/dev/null
    fi

    if [ -f "$blogs_yaml" ]; then
        local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
        yq e ".articles.${article_name}.publish_status = false | .articles.${article_name}.published_at = null | .articles.${article_name}.mod_comments = \"Found ${blacklist_count} blacklisted words (auto-archived by moderator)\" | .articles.${article_name}.read_count = 0" -i "$blogs_yaml"
    fi

    local mod_symlink="$MOD_HOME/${author_username}_public"
    if [ -L "$mod_symlink" ]; then
        rm "$mod_symlink"
    fi
}


check_mod_permission

if [ $# -ne 1 ]; then
    echo "Usage: blogFilter <author_username>"
    exit 1
fi

TARGET_AUTHOR="$1"
AUTHOR_PUBLIC_DIR="/home/authors/$TARGET_AUTHOR/public"
AUTHOR_BLOGS_YAML="/home/authors/$TARGET_AUTHOR/blogs.yaml"

if [ ! -d "/home/authors/$TARGET_AUTHOR" ]; then
    echo "Error: Author '$TARGET_AUTHOR' not found."
    exit 1
fi

MOD_AUTHOR_SYMLINK="$MOD_HOME/${TARGET_AUTHOR}_public"
if [ ! -L "$MOD_AUTHOR_SYMLINK" ]; then
    echo "Error: You are not assigned to moderate blogs by author '$TARGET_AUTHOR'."
    exit 1
fi

if [ ! -f "$BLACKLIST_FILE" ] || [ ! -r "$BLACKLIST_FILE" ]; then
    echo "Error: Blacklist file not found or not readable at $BLACKLIST_FILE"
    exit 1
fi

mapfile -t BLACKLIST_WORDS < <(grep -v '^\s*$' "$BLACKLIST_FILE" | sed 's/[^^$.*\/[\]\\]/\\&/g' | awk '{ print length($0), $0 }' | sort -rn | cut -d' ' -f2-)

if [ ${#BLACKLIST_WORDS[@]} -eq 0 ]; then
    echo "Blacklist file is empty or contains no valid words. Nothing to filter."
    exit 0
fi

echo "Filtering blogs by author '$TARGET_AUTHOR' using blacklist from $BLACKLIST_FILE..."

for ARTICLE_PATH in "$AUTHOR_PUBLIC_DIR"/*.md; do
    if [ ! -f "$ARTICLE_PATH" ]; then
        continue
    fi

    ARTICLE_BASENAME=$(basename "$ARTICLE_PATH")
    ARTICLE_NAME="${ARTICLE_BASENAME%.md}"
    TEMP_ARTICLE_PATH="$ARTICLE_PATH.tmp.$$"

    echo " Processing '$ARTICLE_BASENAME'..."

    BLACKLIST_COUNT_ARTICLE=0

    awk -v author="$TARGET_AUTHOR" -v article="$ARTICLE_NAME" -v blacklist_file="$BLACKLIST_FILE" \
        'BEGIN {
            IGNORECASE = 1
            while (getline word < blacklist_file) {
                gsub(/^[ \t]+|[ \t]+$/, "", word);
                if (length(word) > 0) {
                    blacklist_words[num_blacklist_words++] = word
                }
            }
             for (i = 0; i < num_blacklist_words; i++) {
                 for (j = i + 1; j < num_blacklist_words; j++) {
                     if (length(blacklist_words[i]) < length(blacklist_words[j])) {
                         temp = blacklist_words[i];
                         blacklist_words[i] = blacklist_words[j];
                         blacklist_words[j] = temp;
                     }
                 }
             }
        }

        function generate_asterisks(len) {
            asterisks = "";
            for (k = 0; k < len; k++) asterisks = asterisks "*";
            return asterisks;
        }

        {
            line = $0;
            line_num = NR;
            censored_line = "";
            last_pos = 0;

            while (last_pos < length(line)) {
                best_match_len = 0;
                best_match_word = "";
                best_match_pos = -1;

                for (i = 0; i < num_blacklist_words; i++) {
                    word = blacklist_words[i];
                    current_segment = substr(line, last_pos + 1);
                    match_start = index(tolower(current_segment), tolower(word));

                    if (match_start > 0) {
                         actual_pos = last_pos + match_start;
                         if (best_match_pos == -1 || actual_pos < best_match_pos) {
                             best_match_len = length(word);
                             best_match_word = word;
                             best_match_pos = actual_pos;
                         }
                    }
                }

                if (best_match_pos > 0) {
                    censored_line = censored_line substr(line, last_pos + 1, best_match_pos - last_pos - 1);
                    censored_line = censored_line generate_asterisks(best_match_len);
                    printf " Found blacklisted word \"%s\" in %s.md by %s at line %d\n", best_match_word, article, author, line_num > "/dev/stderr";
                    article_blacklist_count++;
                    last_pos = best_match_pos + best_match_len -1;
                } else {
                    censored_line = censored_line substr(line, last_pos + 1);
                    last_pos = length(line);
                }
            }
            print censored_line;
        }

        END {
             print article_blacklist_count;
        }' "$ARTICLE_PATH" "$BLACKLIST_FILE" > "$TEMP_ARTICLE_PATH"

    BLACKLIST_COUNT_ARTICLE=$(tail -n 1 "$TEMP_ARTICLE_PATH")
    sed -i '$d' "$TEMP_ARTICLE_PATH"

    mv "$TEMP_ARTICLE_PATH" "$ARTICLE_PATH"

    if [ "$BLACKLIST_COUNT_ARTICLE" -gt 5 ]; then
        archive_blog_by_filter "$TARGET_AUTHOR" "$ARTICLE_NAME" "$BLACKLIST_COUNT_ARTICLE"
    fi

done

echo "Blog filtering complete for author '$TARGET_AUTHOR'."

#!/bin/bash

AUTHOR_HOME="/home/authors/$USER"
BLOGS_DIR="$AUTHOR_HOME/blogs"
PUBLIC_DIR="$AUTHOR_HOME/public"
SUBSCRIBERS_ONLY_DIR="$AUTHOR_HOME/subscribers_only"
BLOGS_YAML="$AUTHOR_HOME/blogs.yaml"

check_author_permission() {
    if ! id -Gn | grep -q "g_author"; then
        echo "Error: This command can only be run by an author."
        exit 1
    fi
}

ensure_blog_dirs() {
    mkdir -p "$BLOGS_DIR" "$PUBLIC_DIR" "$SUBSCRIBERS_ONLY_DIR"
    if [ ! -f "$BLOGS_YAML" ]; then
         echo 'articles: {}' > "$BLOGS_YAML"
    fi
}

validate_article_name() {
    local article_name="$1"
    if [[ ! "$article_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "Error: Invalid article name. Use only letters, numbers, hyphens, and underscores."
        exit 1
    fi
}

get_article_path() {
    local article_name="$1"
    echo "$BLOGS_DIR/${article_name}.md"
}

article_exists() {
    local article_name="$1"
    [ -f "$(get_article_path "$article_name")" ]
}

get_timestamp() {
    date +"%Y-%m-%d %H:%M:%S"
}

read_blog_metadata() {
    local article_name="$1"
    yq e ".articles.${article_name}" "$BLOGS_YAML" 2>/dev/null
}

article_metadata_exists() {
    local article_name="$1"
    yq e ".articles | has(\"$article_name\")" "$BLOGS_YAML" | grep -q "true"
}


cmd_create() {
    local article_name="$1"
    if [ -z "$article_name" ]; then
        echo "Usage: manageBlogs create <article_name>"
        exit 1
    fi

    validate_article_name "$article_name"
    ensure_blog_dirs

    local article_path=$(get_article_path "$article_name")

    if [ -f "$article_path" ]; then
        echo "Error: Article '$article_name' already exists."
        exit 1
    fi

    touch "$article_path"
    echo "Article '$article_name' created at $article_path"

    local timestamp=$(get_timestamp)
    yq e ".articles.${article_name} = {title: \"$article_name\", tags: [], publish_status: false, created_at: \"$timestamp\", updated_at: \"$timestamp\", read_count: 0, mod_comments: \"\"}" -i "$BLOGS_YAML"
    echo "Metadata added to $BLOGS_YAML"

    echo "You can now edit the article using 'manageBlogs edit $article_name'"
}

cmd_edit() {
    local article_name="$1"
    if [ -z "$article_name" ]; then
        echo "Usage: manageBlogs edit <article_name>"
        exit 1
    fi

    validate_article_name "$article_name"
    local article_path=$(get_article_path "$article_name")

    if ! article_exists "$article_name"; then
        echo "Error: Article '$article_name' not found in $BLOGS_DIR."
        exit 1
    fi

    ${EDITOR:-nano} "$article_path"

    local timestamp=$(get_timestamp)
    yq e ".articles.${article_name}.updated_at = \"$timestamp\"" -i "$BLOGS_YAML"
    echo "Updated '$article_name'. Metadata updated."
}

cmd_publish() {
    local article_name="$1"
    local publish_type="$2"

    if [ -z "$article_name" ]; then
        echo "Usage: manageBlogs publish <article_name> [public|subscribers]"
        exit 1
    fi

    validate_article_name "$article_name"
    ensure_blog_dirs

    local article_path=$(get_article_path "$article_name")

    if ! article_exists "$article_name"; then
        echo "Error: Article '$article_name' not found in $BLOGS_DIR."
        exit 1
    fi

    local target_dir="$PUBLIC_DIR"
    local status="true"
    local message="publicly"

    if [ -n "$publish_type" ]; then
        case "$publish_type" in
            public)
                target_dir="$PUBLIC_DIR"
                status="true"
                message="publicly"
                ;;
            subscribers)
                target_dir="$SUBSCRIBERS_ONLY_DIR"
                status='"subscribers_only"'
                message="for subscribers only"
                 mkdir -p "$target_dir"
                 chown "$USER":g_author "$target_dir"
                 chmod 700 "$target_dir"
                ;;
            *)
                echo "Error: Invalid publish type '$publish_type'. Use 'public' or 'subscribers'."
                exit 1
                ;;
        esac
    fi

    local target_path="$target_dir/${article_name}.md"

    cp "$article_path" "$target_path"

    if [ "$target_dir" == "$PUBLIC_DIR" ]; then
        chmod 644 "$target_path"
         setfacl -m g:g_user:r-x "$target_path"
         setfacl -m g:g_mod:rwx "$target_path"
         setfacl -d -m g:g_user:r-x "$target_path"
         setfacl -d -m g:g_mod:rwx "$target_path"
    elif [ "$target_dir" == "$SUBSCRIBERS_ONLY_DIR" ]; then
         chmod 640 "$target_path"
         setfacl -m g:g_user:r-x "$target_path"
         setfacl -d -m g:g_user:r-x "$target_path"
    fi
    chown "$USER":g_author "$target_path"

    local timestamp=$(get_timestamp)
    yq e ".articles.${article_name}.publish_status = $status | .articles.${article_name}.published_at = \"$timestamp\" | .articles.${article_name}.read_count = 0 | .articles.${article_name}.mod_comments = \"\"" -i "$BLOGS_YAML"
     echo "Article '$article_name' published $message."

    if [ "$status" == '"subscribers_only"' ]; then
         echo "Note: Subscribers will receive this article when the admin runs subscriptionModel updates."
    fi
}

cmd_archive() {
    local article_name="$1"
     if [ -z "$article_name" ]; then
        echo "Usage: manageBlogs archive <article_name>"
        exit 1
    fi

    validate_article_name "$article_name"

    if ! article_exists "$article_name"; then
        echo "Error: Article '$article_name' not found in $BLOGS_DIR."
        exit 1
    fi

    if ! article_metadata_exists "$article_name"; then
         echo "Error: Metadata for '$article_name' not found in $BLOGS_YAML."
         exit 1
    fi

    local status=$(yq e ".articles.${article_name}.publish_status" "$BLOGS_YAML")

    if [ "$status" == "false" ]; then
        echo "Article '$article_name' is already archived or not published."
        exit 0
    fi

    if [ -f "$PUBLIC_DIR/${article_name}.md" ]; then
        rm "$PUBLIC_DIR/${article_name}.md"
         setfacl -b "$PUBLIC_DIR/${article_name}.md" 2>/dev/null
        echo "Removed '$article_name' from public directory."
    fi
    if [ -f "$SUBSCRIBERS_ONLY_DIR/${article_name}.md" ]; then
        rm "$SUBSCRIBERS_ONLY_DIR/${article_name}.md"
         setfacl -b "$SUBSCRIBERS_ONLY_DIR/${article_name}.md" 2>/dev/null
        echo "Removed '$article_name' from subscribers-only directory."
    fi

    yq e ".articles.${article_name}.publish_status = false | .articles.${article_name}.published_at = null | .articles.${article_name}.read_count = 0" -i "$BLOGS_YAML"
    echo "Article '$article_name' archived."
}

cmd_delete() {
    local article_name="$1"
     if [ -z "$article_name" ]; then
        echo "Usage: manageBlogs delete <article_name>"
        exit 1
    fi

    validate_article_name "$article_name"

    if ! article_exists "$article_name"; then
        echo "Error: Article '$article_name' not found in $BLOGS_DIR."
        exit 1
    fi

    rm "$BLOGS_DIR/${article_name}.md"
    echo "Original blog file '$article_name.md' deleted."

    if [ -f "$PUBLIC_DIR/${article_name}.md" ]; then
        rm "$PUBLIC_DIR/${article_name}.md"
         setfacl -b "$PUBLIC_DIR/${article_name}.md" 2>/dev/null
        echo "Removed '$article_name' from public directory."
    fi
     if [ -f "$SUBSCRIBERS_ONLY_DIR/${article_name}.md" ]; then
        rm "$SUBSCRIBERS_ONLY_DIR/${article_name}.md"
         setfacl -b "$SUBSCRIBERS_ONLY_DIR/${article_name}.md" 2>/dev/null
        echo "Removed '$article_name' from subscribers-only directory."
    fi

    local timestamp=$(get_timestamp)
    yq e ".articles.${article_name}.publish_status = \"deleted\" | .articles.${article_name}.deleted_at = \"$timestamp\"" -i "$BLOGS_YAML"
    echo "Article '$article_name' metadata marked as deleted in $BLOGS_YAML."
}

cmd_list() {
    ensure_blog_dirs

    if [ ! -f "$BLOGS_YAML" ] || [ "$(yq e '.articles | length' "$BLOGS_YAML")" -eq 0 ]; then
        echo "No blogs found for author $USER."
        return
    fi

    echo "Blogs for Author $USER:"
    yq e '.articles | keys[]' "$BLOGS_YAML" | while read -r article_name; do
        local title=$(yq e ".articles.${article_name}.title" "$BLOGS_YAML")
        local status=$(yq e ".articles.${article_name}.publish_status" "$BLOGS_YAML")
        local tags=$(yq e ".articles.${article_name}.tags | join(\", \")" "$BLOGS_YAML")
        local created=$(yq e ".articles.${article_name}.created_at" "$BLOGS_YAML")
        local published=$(yq e ".articles.${article_name}.published_at // \"N/A\"" "$BLOGS_YAML")
         local deleted=$(yq e ".articles.${article_name}.deleted_at // \"N/A\"" "$BLOGS_YAML")
         local reads=$(yq e ".articles.${article_name}.read_count // 0" "$BLOGS_YAML")

        echo "--- $title ($article_name.md) ---"
        echo "  Status: $status"
        echo "  Tags: [$tags]"
        echo "  Created: $created"
        echo "  Published: $published"
         echo "  Deleted: $deleted"
         echo "  Reads: $reads"
        echo "----------------------------"
    done
}

cmd_add_tags() {
    local article_name="$1"
    local tags_string="$2"

     if [ -z "$article_name" ] || [ -z "$tags_string" ]; then
        echo "Usage: manageBlogs add_tags <article_name> <tag1,tag2,...>"
        exit 1
    fi

    validate_article_name "$article_name"

    if ! article_metadata_exists "$article_name"; then
         echo "Error: Metadata for '$article_name' not found in $BLOGS_YAML."
         exit 1
    fi

    local tags_array=$(echo "$tags_string" | awk -F',' '{
        printf "["
        for(i=1; i<=NF; i++) {
            gsub(/^ */,"",$i); gsub(/ *$/,"",$i);
            printf "\"%s\"", $i
            if(i < NF) printf ", "
        }
        printf "]"
    }')

    yq e ".articles.${article_name}.tags |= (. + ${tags_array} | unique)" -i "$BLOGS_YAML"
    echo "Tags added/updated for '$article_name'."
}


check_author_permission

COMMAND="$1"
shift

case "$COMMAND" in
    create)
        cmd_create "$@"
        ;;
    edit)
        cmd_edit "$@"
        ;;
    publish)
        cmd_publish "$@"
        ;;
    archive)
        cmd_archive "$@"
        ;;
    delete)
        cmd_delete "$@"
        ;;
    list)
        cmd_list "$@"
        ;;
    add_tags)
        cmd_add_tags "$@"
        ;;
    *)
        echo "Usage: manageBlogs <command> [arguments]"
        echo "Commands:"
        echo "  create <article_name>"
        echo "  edit <article_name>"
        echo "  publish <article_name> [public|subscribers]"
        echo "  archive <article_name>"
        echo "  delete <article_name>"
        echo "  list"
        echo "  add_tags <article_name> <tag1,tag2,...>"
        exit 1
        ;;
esac

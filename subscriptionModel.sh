#!/bin/bash

USERS_YAML="/opt/blog_system/users.yaml"
SUBSCRIPTIONS_YAML="/opt/blog_system/subscriptions.yaml"
USER_GROUP="g_user"
ADMIN_GROUP="g_admin"

check_user_or_admin_permission() {
    if ! id -Gn | grep -q "$USER_GROUP" && ! id -Gn | grep -q "$ADMIN_GROUP"; then
        echo "Error: This command can only be run by a user or an admin."
        exit 1
    fi
}

check_user_permission() {
     if ! id -Gn | grep -q "$USER_GROUP"; then
        echo "Error: This command can only be run by a user for subscription management."
        exit 1
    fi
}

check_admin_permission() {
     if ! id -Gn | grep -q "$ADMIN_GROUP"; then
        echo "Error: This action (distribute) can only be run by an admin."
        exit 1
    fi
}


cmd_subscribe() {
    check_user_permission

    local author_username="$1"
    local user_username="$USER"
    local user_home="/home/users/$user_username"
    local subscribed_blogs_dir="$user_home/subscribed_blogs"

    if [ -z "$author_username" ]; then
        echo "Usage: subscriptionModel subscribe <author_username>"
        exit 1
    fi

    if [ ! -d "/home/authors/$author_username" ]; then
        echo "Error: Author '$author_username' not found."
        exit 1
    fi

    local is_subscribed=$(yq e ".subscriptions.${user_username}[] | select(. == \"$author_username\")" "$SUBSCRIPTIONS_YAML" 2>/dev/null)
    if [ -n "$is_subscribed" ]; then
        echo "You are already subscribed to author '$author_username'."
        exit 0
    fi

    if yq e ".subscriptions.${user_username} += [\"$author_username\"]" -i "$SUBSCRIPTIONS_YAML"; then
        echo "Successfully subscribed to author '$author_username'."
        mkdir -p "$subscribed_blogs_dir"
        chown "$user_username":g_user "$subscribed_blogs_dir"
        chmod 700 "$subscribed_blogs_dir"

        local author_subs_dir="/home/authors/$author_username/subscribers_only"
        local symlink_path="$subscribed_blogs_dir/$author_username"

        if [ -d "$author_subs_dir" ]; then
            if [ ! -L "$symlink_path" ]; then
                 ln -s "$author_subs_dir" "$symlink_path"
                 chown "$user_username":g_user "$symlink_path"
                 chmod 700 "$symlink_path"
                 echo " You can find subscriber-only content in $subscribed_blogs_dir/$author_username/"
             else
             fi
        else
        fi

    else
        echo "Error: Could not update subscription data. Permission issue or yq error."
        exit 1
    fi
}

cmd_unsubscribe() {
    check_user_permission

    local author_username="$1"
    local user_username="$USER"
    local user_home="/home/users/$user_username"
    local subscribed_blogs_dir="$user_home/subscribed_blogs"

    if [ -z "$author_username" ]; then
        echo "Usage: subscriptionModel unsubscribe <author_username>"
        exit 1
    fi

    local is_subscribed=$(yq e ".subscriptions.${user_username}[] | select(. == \"$author_username\")" "$SUBSCRIPTIONS_YAML" 2>/dev/null)
    if [ -z "$is_subscribed" ]; then
        echo "You are not subscribed to author '$author_username'."
        exit 0
    fi

    if yq e "del(.subscriptions.${user_username}[] | select(. == \"$author_username\"))" -i "$SUBSCRIPTIONS_YAML"; then
        echo "Successfully unsubscribed from author '$author_username'."
         local symlink_path="$subscribed_blogs_dir/$author_username"
         if [ -L "$symlink_path" ]; then
             rm "$symlink_path"
         fi
    else
        echo "Error: Could not update subscription data. Permission issue or yq error."
        exit 1
    fi
}

cmd_list_subscriptions() {
    check_user_permission

    local user_username="$USER"

    echo "Subscriptions for $user_username:"
    if [ ! -f "$SUBSCRIPTIONS_YAML" ] || [ "$(yq e ".subscriptions.${user_username} | length // 0" "$SUBSCRIPTIONS_YAML")" -eq 0 ]; then
        echo " You are not subscribed to any authors."
        return
    fi

    yq e ".subscriptions.${user_username}[]" "$SUBSCRIPTIONS_YAML" | while read -r author; do
        echo " - $author"
    done
}

cmd_distribute_content() {
    check_admin_permission

    echo "Starting subscriber-only content distribution..."

    if [ ! -f "$USERS_YAML" ] || [ ! -f "$SUBSCRIPTIONS_YAML" ]; then
         echo "Error: Required YAML files (users.yaml, subscriptions.yaml) not found."
         exit 1
    fi

    mapfile -t SUBSCRIBING_USERS < <(yq e ".subscriptions | keys[]" "$SUBSCRIPTIONS_YAML")

    if [ ${#SUBSCRIBING_USERS[@]} -eq 0 ]; then
         echo "No users with active subscriptions found. Distribution skipped."
         exit 0
    fi

    mapfile -t ALL_AUTHORS < <(yq e ".authors[].username" "$USERS_YAML"))

    for author_username in "${ALL_AUTHORS[@]}"; do
        local author_subs_dir="/home/authors/$author_username/subscribers_only"
        local author_blogs_yaml="/home/authors/$author_username/blogs.yaml"

        if [ ! -d "$author_subs_dir" ] || [ ! -f "$author_blogs_yaml" ]; then
            continue
        fi

        echo " Processing subscriber-only content for author '$author_username'..."

        mapfile -t SUBSCRIBER_ONLY_ARTICLES < <(yq e ".articles | to_entries[] | select(.value.publish_status == \"subscribers_only\" and .value.distributed_at == null) | .key" "$author_blogs_yaml")

        if [ ${#SUBSCRIBER_ONLY_ARTICLES[@]} -eq 0 ]; then
            echo "  No new subscriber-only articles found for '$author_username'."
            continue
        fi

        local current_timestamp=$(date +"%Y-%m-%d %H:%M:%S")

        for article_name in "${SUBSCRIBER_ONLY_ARTICLES[@]}"; do
            local article_path="$author_subs_dir/${article_name}.md"
            if [ ! -f "$article_path" ]; then
                 echo "  Warning: Article file not found for subscriber-only blog '$article_name' by '$author_username'. Skipping distribution."
                 continue
            fi
             echo "  Distributing article '$article_name'..."

            mapfile -t SUBSCRIBED_TO_AUTHOR < <(yq e ".subscriptions | to_entries[] | select(.value[] | . == \"$author_username\") | .key" "$SUBSCRIPTIONS_YAML")

            for user_username in "${SUBSCRIBED_TO_AUTHOR[@]}"; do
                local user_subscribed_blogs_dir="/home/users/$user_username/subscribed_blogs/$author_username"

                if [ -d "$user_subscribed_blogs_dir" ]; then
                    echo "   User '$user_username' has access via symlink."
                else
                     echo "   Warning: User '$user_username' subscribed, but their subscribed_blogs/$author_username directory symlink is missing."
                fi
            done

            yq e ".articles.${article_name}.distributed_at = \"$current_timestamp\"" -i "$author_blogs_yaml"
            echo "  Marked article '$article_name' as distributed for author '$author_username'."

        done
    done

    echo "Subscriber-only content distribution finished."
}


check_user_or_admin_permission

COMMAND="$1"
shift

case "$COMMAND" in
    subscribe)
        cmd_subscribe "$@"
        ;;
    unsubscribe)
        cmd_unsubscribe "$@"
        ;;
    list)
        cmd_list_subscriptions "$@"
        ;;
    distribute)
        cmd_distribute_content "$@"
        ;;
    *)
        echo "Usage (User): subscriptionModel <command> [arguments]"
        echo "Commands (User):"
        echo "  subscribe <author_username>"
        echo "  unsubscribe <author_username>"
        echo "  list"
        echo ""
        echo "Usage (Admin): subscriptionModel distribute"
        echo "Commands (Admin):"
        echo "  distribute"
        exit 1
        ;;
esac

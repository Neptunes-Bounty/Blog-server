#!/bin/bash

USERS_YAML="/opt/blog_system/users.yaml"
USERPREF_YAML="/opt/blog_system/userpref.yaml"
ADMIN_GROUP="g_admin"
NUMBER_OF_BLOGS_FY=3

check_admin_permission() {
    if ! id -Gn | grep -q "$ADMIN_GROUP"; then
        echo "Error: This command can only be run by an admin."
        exit 1
    fi
}

check_admin_permission

if [ ! -f "$USERS_YAML" ]; then
    echo "Error: users.yaml not found at $USERS_YAML"
    exit 1
fi

if [ ! -f "$USERPREF_YAML" ]; then
    echo "Error: userpref.yaml not found at $USERPREF_YAML"
    exit 1
fi

echo "Generating 'For You' blog recommendations for users..."

declare -A all_published_blogs
declare -A blog_assignment_count
declare -A blog_to_author

ALL_AUTHORS=($(yq e ".authors[].username" "$USERS_YAML"))
for author_username in "${ALL_AUTHORS[@]}"; do
    AUTHOR_BLOGS_YAML="/home/authors/$author_username/blogs.yaml"
    if [ -f "$AUTHOR_BLOGS_YAML" ]; then
        PUBLISHED_ARTICLES=($(yq e ".articles | to_entries[] | select(.value.publish_status == true) | .key" "$AUTHOR_BLOGS_YAML"))

        for article_name in "${PUBLISHED_ARTICLES[@]}"; do
            local blog_key="${author_username}/${article_name}"
            local title=$(yq e ".articles.${article_name}.title" "$AUTHOR_BLOGS_YAML")
            local tags_string=$(yq e ".articles.${article_name}.tags | join(\",\")" "$AUTHOR_BLOGS_YAML")
            local read_count=$(yq e ".articles.${article_name}.read_count // 0" "$AUTHOR_BLOGS_YAML")

            all_published_blogs["$blog_key"]="${author_username}|${title}|${tags_string}|${read_count}"
            blog_assignment_count["$blog_key"]=0
            blog_to_author["$blog_key"]="$author_username"
        done
    fi
done

if [ ${#all_published_blogs[@]} -eq 0 ]; then
    echo "No public blogs available to recommend. Exiting."
    exit 0
fi

declare -A user_preferences
declare -A user_recommendations

ALL_USERS=($(yq e ".users[].username" "$USERS_YAML"))
for user_username in "${ALL_USERS[@]}"; do
    PREFS_STRING=$(yq e ".users.${user_username}.preferences | join(\",\")" "$USERPREF_YAML" 2>/dev/null)
    if [ -n "$PREFS_STRING" ]; then
        IFS=',' read -ra preferences_array <<< "$PREFS_STRING"
        user_preferences["$user_username"]="${preferences_array[*]}"
        user_recommendations["$user_username"]=""
    else
        user_preferences["$user_username"]=""
        user_recommendations["$user_username"]=""
    fi
done

read -ra BLOG_KEYS <<< "${!all_published_blogs[*]}"
for (( i=${#BLOG_KEYS[@]}-1; i>0; i-- )); do
    j=$(( RANDOM % (i+1) ))
    temp="${BLOG_KEYS[i]}"
    BLOG_KEYS[i]="${BLOG_KEYS[j]}"
    BLOG_KEYS[j]="$temp"
done

for user_username in "${ALL_USERS[@]}"; do
    local user_prefs_string="${user_preferences[$user_username]}"
    local current_recommendations_count=0
    local assigned_blogs=()

    if [ -n "$user_prefs_string" ]; then
        read -ra user_prefs_array <<< "$user_prefs_string"

        declare -A blog_scores
        for blog_key in "${BLOG_KEYS[@]}"; do
            local blog_info="${all_published_blogs[$blog_key]}"
            local tags_string=$(echo "$blog_info" | cut -d'|' -f3)
            local score=0
            if [ -n "$tags_string" ]; then
                 IFS=',' read -ra blog_tags_array <<< "$tags_string"
                 for tag in "${blog_tags_array[@]}"; do
                     for pref_index in "${!user_prefs_array[@]}"; do
                         if [ "$tag" == "${user_prefs_array[$pref_index]}" ]; then
                             score=$(( score + ${#user_prefs_array[@]} - pref_index ))
                             break
                         fi
                     done
                 done
            fi
            blog_scores["$blog_key"]="$score"
        done

        mapfile -t sorted_blog_keys < <(for blog_key in "${BLOG_KEYS[@]}"; do echo "${blog_scores[$blog_key]}|${blog_key}"; done | sort -r -t'|' -k1,1 | cut -d'|' -f2-)

        for blog_key in "${sorted_blog_keys[@]}"; do
            if [ "$current_recommendations_count" -ge "$NUMBER_OF_BLOGS_FY" ]; then
                break
            fi
            local already_assigned=false
             for assigned in "${assigned_blogs[@]}"; do
                 if [ "$assigned" == "$blog_key" ]; then
                     already_assigned=true
                     break
                 fi
             done

            if [ "$already_assigned" == false ]; then
                 local total_blogs=${#BLOG_KEYS[@]}
                 local total_users=${#ALL_USERS[@]}
                 local avg_assign_limit=0
                 if [ "$total_users" -gt 0 ]; then
                     avg_assign_limit=$(( (total_blogs * NUMBER_OF_BLOGS_FY + total_users - 1) / total_users ))
                     avg_assign_limit=$(( avg_assign_limit + 1 ))
                 else
                     avg_assign_limit="$NUMBER_OF_BLOGS_FY"
                 fi

                if [ "${blog_assignment_count[$blog_key]}" -lt "$avg_assign_limit" ]; then
                     assigned_blogs+=("$blog_key")
                     blog_assignment_count["$blog_key"]=$(( blog_assignment_count["$blog_key"] + 1 ))
                     current_recommendations_count=$(( current_recommendations_count + 1 ))
                 fi
            fi
        done
    fi

    local remaining_blog_keys=()
    for blog_key in "${BLOG_KEYS[@]}"; do
        local already_assigned=false
        for assigned in "${assigned_blogs[@]}"; do
            if [ "$assigned" == "$blog_key" ]; then
                already_assigned=true
                break
            fi
        done
        if [ "$already_assigned" == false ]; then
            remaining_blog_keys+=("$blog_key")
        fi
    done

     mapfile -t remaining_sorted_by_count < <(for blog_key in "${remaining_blog_keys[@]}"; do echo "${blog_assignment_count[$blog_key]}|${blog_key}"; done | sort -n -t'|' -k1,1 | cut -d'|' -f2-)

     for blog_key in "${remaining_sorted_by_count[@]}"; do
         if [ "$current_recommendations_count" -ge "$NUMBER_OF_BLOGS_FY" ]; then
             break
         fi
         assigned_blogs+=("$blog_key")
         blog_assignment_count["$blog_key"]=$(( blog_assignment_count["$blog_key"] + 1 ))
         current_recommendations_count=$(( current_recommendations_count + 1 ))
     done

    user_recommendations["$user_username"]="${assigned_blogs[*]}"

done

for user_username in "${ALL_USERS[@]}"; do
    local user_home="/home/users/$user_username"
    local fyi_yaml="$user_home/FYI.yaml"
    local recommended_blogs_keys="${user_recommendations[$user_username]}"

    if [ -z "$recommended_blogs_keys" ]; then
        echo 'recommended_blogs: []' > "$fyi_yaml"
        chown "$user_username":g_user "$fyi_yaml"
        chmod 600 "$fyi_yaml"
        continue
    fi

    local yaml_output="recommended_blogs:"

    read -ra recommended_keys_array <<< "$recommended_blogs_keys"
    for blog_key in "${recommended_keys_array[@]}"; do
        local blog_info="${all_published_blogs[$blog_key]}"
        local author=$(echo "$blog_info" | cut -d'|' -f1)
        local title=$(echo "$blog_info" | cut -d'|' -f2)
        local article_name=$(echo "$blog_key" | cut -d'/' -f2)

        yaml_output+="\n  - author: \"$author\""
        yaml_output+="\n    article: \"$article_name\""
        yaml_output+="\n    title: \"$title\""
    done

    echo -e "$yaml_output" > "$fyi_yaml"
    chown "$user_username":g_user "$fyi_yaml"
    chmod 600 "$fyi_yaml"

done

echo "'For You' recommendation process finished."

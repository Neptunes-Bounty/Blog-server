#!/bin/bash

YAML_FILE="/opt/blog_system/users.yaml"
SCRIPT_DIR="/scripts"

setup_user_home() {
    local username="$1"
    local group="$2"
    local home_dir="$3"
    local user_type="$4"

    if [ ! -d "$home_dir" ]; then
        mkdir -p "$home_dir"
        chown "$username":"$group" "$home_dir"
        chmod 700 "$home_dir"
    else
        chown "$username":"$group" "$home_dir"
        chmod 700 "$home_dir"
    fi

    case "$user_type" in
        author)
            mkdir -p "$home_dir/blogs" "$home_dir/public" "$home_dir/subscribers_only"
            chown "$username":"$group" "$home_dir/blogs" "$home_dir/public" "$home_dir/subscribers_only"
            chmod 700 "$home_dir/blogs" "$home_dir/subscribers_only"
            chmod 750 "$home_dir/public"
            if [ ! -f "$home_dir/blogs.yaml" ]; then
                echo 'articles: {}' > "$home_dir/blogs.yaml"
                chown "$username":"$group" "$home_dir/blogs.yaml"
                chmod 600 "$home_dir/blogs.yaml"
            else
                chown "$username":"$group" "$home_dir/blogs.yaml"
                chmod 600 "$home_dir/blogs.yaml"
            fi
            ;;
        user)
            mkdir -p "$home_dir/all_blogs" "$home_dir/subscribed_blogs"
            chown "$username":"$group" "$home_dir/all_blogs" "$home_dir/subscribed_blogs"
            chmod 700 "$home_dir/all_blogs" "$home_dir/subscribed_blogs"
            if [ ! -f "$home_dir/FYI.yaml" ]; then
                echo 'recommended_blogs: []' > "$home_dir/FYI.yaml"
                chown "$username":"$group" "$home_dir/FYI.yaml"
                chmod 600 "$home_dir/FYI.yaml"
            else
                chown "$username":"$group" "$home_dir/FYI.yaml"
                chmod 600 "$home_dir/FYI.yaml"
            fi
            ;;
        mod)
            if [ ! -f "$home_dir/blacklist.txt" ]; then
                touch "$home_dir/blacklist.txt"
                chown "$username":"$group" "$home_dir/blacklist.txt"
                chmod 600 "$home_dir/blacklist.txt"
                 echo "Sample blacklist words:" >> "$home_dir/blacklist.txt"
                 echo "badword1" >> "$home_dir/blacklist.txt"
                 echo "badword2" >> "$home_dir/blacklist.txt"
            else
                 chown "$username":"$group" "$home_dir/blacklist.txt"
                 chmod 600 "$home_dir/blacklist.txt"
            fi
            ;;
        admin)
            ;;
    esac
}

create_or_update_user() {
    local username="$1"
    local primary_group="$2"
    local additional_groups="$3"
    local home_dir="$4"
    local user_type="$5"

    if id -u "$username" >/dev/null 2>&1; then
        usermod -g "$primary_group" -G "$additional_groups" "$username"
        usermod -d "$home_dir" "$username"
    else
        local shell="/sbin/nologin"
        if [ "$user_type" == "admin" ]; then
            shell="/bin/bash"
        fi
        useradd -m -d "$home_dir" -g "$primary_group" -G "$additional_groups" -s "$shell" "$username"
        if [ $? -ne 0 ]; then
            exit 1
        fi
        echo "$username:password123" | chpasswd
    fi

    setup_user_home "$username" "$primary_group" "$home_dir" "$user_type"
}

set_user_acls() {
    local username="$1"
    local user_type="$2"
    local admin_group="$3"
    local mod_group="$4"
    local user_group="$5"

    local home_dir
    case "$user_type" in
        admin) home_dir="/home/admin/$username";;
        author) home_dir="/home/authors/$username";;
        mod) home_dir="/home/mods/$username";;
        user) home_dir="/home/users/$username";;
        *) return;;
    esac

    for admin_user in $(yq e ".admins[].username" "$YAML_FILE"); do
        for dir in /home/users /home/authors /home/mods /home/admin; do
            if [ -d "$dir" ]; then
                setfacl -R -m u:"$admin_user":rwx "$dir"
                setfacl -dR -m u:"$admin_user":rwx "$dir"
            fi
        done
    done

    if [ "$user_type" == "author" ]; then
        setfacl -m g:"$mod_group":rwx "$home_dir/public"
        setfacl -d -m g:"$mod_group":rwx "$home_dir/public"
        setfacl -m g:"$mod_group":rw- "$home_dir/blogs.yaml"
    fi
}

manage_mod_symlinks() {
    local mod_username="$1"
    local mod_home="/home/mods/$mod_username"
    local assigned_authors_string="$2"

    local current_assignments=()
    if [ -n "$assigned_authors_string" ]; then
        read -ra current_assignments <<< "$assigned_authors_string"
    fi

    local existing_symlinks=()
    if [ -d "$mod_home" ]; then
        existing_symlinks=( $(find "$mod_home" -maxdepth 1 -lname "/home/authors/*" -print) )
    fi

    for symlink_path in "${existing_symlinks[@]}"; do
        local target="$(readlink -f "$symlink_path")"
        local author_dir="$(basename "$target")"
        local author_name="$(basename "$(dirname "$target")")"
        local author_username=""

        if [[ "$target" =~ ^/home/authors/([^/]+)/public$ ]]; then
             author_username="${BASH_REMATCH[1]}"
        fi

        local found=false
        for assigned_author in "${current_assignments[@]}"; do
            if [ "$author_username" == "$assigned_author" ]; then
                found=true
                break
            done
        done

        if [ "$found" == false ]; then
            rm "$symlink_path"
        fi
    done

    for author_username in "${current_assignments[@]}"; do
        local author_public_dir="/home/authors/$author_username/public"
        local symlink_path="$mod_home/${author_username}_public"
        if [ -d "$author_public_dir" ]; then
            if [ ! -L "$symlink_path" ]; then
                ln -s "$author_public_dir" "$symlink_path"
                chown "$mod_username":g_mod "$symlink_path"
                chmod 700 "$symlink_path"
            else
                chown "$mod_username":g_mod "$symlink_path"
                chmod 700 "$symlink_path"
            fi
        fi
    done
}

manage_user_all_blogs_symlinks() {
    local user_username="$1"
    local user_home="/home/users/$user_username"
    local all_blogs_dir="$user_home/all_blogs"

    local all_authors=($(yq e ".authors[].username" "$YAML_FILE"))

    if [ -d "$all_blogs_dir" ]; then
        find "$all_blogs_dir" -maxdepth 1 -type l -delete
    else
        return
    fi

    for author_username in "${all_authors[@]}"; do
        local author_public_dir="/home/authors/$author_username/public"
        local symlink_path="$all_blogs_dir/$author_username"
        if [ -d "$author_public_dir" ]; then
            ln -s "$author_public_dir" "$symlink_path"
            chown "$user_username":g_user "$symlink_path"
            chmod 700 "$symlink_path"
        fi
    done
}


if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run with root privileges."
    exit 1
fi

ADMIN_GROUP="g_admin"
AUTHOR_GROUP="g_author"
MOD_GROUP="g_mod"
USER_GROUP="g_user"

if ! command -v yq &> /dev/null; then
    echo "Error: yq is not installed. Please install yq."
    exit 1
fi

if [ ! -f "$YAML_FILE" ]; then
    echo "Error: users.yaml not found at $YAML_FILE"
    exit 1
fi

groupadd -f "$ADMIN_GROUP"
groupadd -f "$AUTHOR_GROUP"
groupadd -f "$MOD_GROUP"
groupadd -f "$USER_GROUP"

declare -A users_in_yaml

ADMIN_USERS=($(yq e ".admins[].username" "$YAML_FILE"))
for user in "${ADMIN_USERS[@]}"; do
    users_in_yaml["$user"]=1
    create_or_update_user "$user" "$ADMIN_GROUP" "$ADMIN_GROUP" "/home/admin/$user" "admin"
done

AUTHOR_USERS=($(yq e ".authors[].username" "$YAML_FILE"))
for user in "${AUTHOR_USERS[@]}"; do
    users_in_yaml["$user"]=1
    create_or_update_user "$user" "$AUTHOR_GROUP" "$AUTHOR_GROUP" "/home/authors/$user" "author"
done

MOD_USERS=($(yq e ".mods[].username" "$YAML_FILE"))
declare -A mod_assignments
for i in $(seq 0 $(($(yq e ".mods | length - 1" "$YAML_FILE")))); do
    mod_user=$(yq e ".mods[$i].username" "$YAML_FILE")
    assigned_authors_string=$(yq e ".mods[$i].authors[]" "$YAML_FILE" | xargs)
    users_in_yaml["$mod_user"]=1
    mod_assignments["$mod_user"]="$assigned_authors_string"
    create_or_update_user "$mod_user" "$MOD_GROUP" "$MOD_GROUP" "/home/mods/$mod_user" "mod"
done

REGULAR_USERS=($(yq e ".users[].username" "$YAML_FILE"))
for user in "${REGULAR_USERS[@]}"; do
    users_in_yaml["$user"]=1
    create_or_update_user "$user" "$USER_GROUP" "$USER_GROUP" "/home/users/$user" "user"
done

ALL_OUR_GROUPS=("$ADMIN_GROUP" "$AUTHOR_GROUP" "$MOD_GROUP" "$USER_GROUP")
for group in "${ALL_OUR_GROUPS[@]}"; do
    mapfile -t group_users < <(getent group "$group" | cut -d: -f4 | tr ',' '\n')
    for user in "${group_users[@]}"; do
        if [ -z "${users_in_yaml[$user]}" ]; then
             for g in "${ALL_OUR_GROUPS[@]}"; do
                 gpasswd -d "$user" "$g" 2>/dev/null
             done
        fi
    done
done

for user in "${ADMIN_USERS[@]}"; do set_user_acls "$user" "admin" "$ADMIN_GROUP" "$MOD_GROUP" "$USER_GROUP"; done
for user in "${AUTHOR_USERS[@]}"; do set_user_acls "$user" "author" "$ADMIN_GROUP" "$MOD_GROUP" "$USER_GROUP"; done
for user in "${MOD_USERS[@]}"; do set_user_acls "$user" "mod" "$ADMIN_GROUP" "$MOD_GROUP" "$USER_GROUP"; done
for user in "${REGULAR_USERS[@]}"; do set_user_acls "$user" "user" "$ADMIN_GROUP" "$MOD_GROUP" "$USER_GROUP"; done

for mod_user in "${MOD_USERS[@]}"; do
    manage_mod_symlinks "$mod_user" "${mod_assignments[$mod_user]}"
done
for user in "${REGULAR_USERS[@]}"; do
     manage_user_all_blogs_symlinks "$user"
done

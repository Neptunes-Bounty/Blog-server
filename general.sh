sudo mkdir /scripts
sudo mkdir /opt/blog_system
sudo mkdir -p /home/users /home/authors /home/mods /home/admin
sudo chown root:root /scripts /opt/blog_system /home/*
sudo chmod 755 /scripts /opt/blog_system
sudo chmod 700 /home/users /home/authors /home/mods /home/admin
sudo groupadd g_admin
sudo groupadd g_author
sudo groupadd g_mod
sudo groupadd g_user
export PATH=$PATH:/scripts

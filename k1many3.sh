#!/usr/bin/env bash

help_messages () {
    echo "Usage: sh k1many.sh [option] [folder1] [folder2] [folder2]"
    echo "Script that can start multiple sites."
    echo
    echo "--build       Start the site and initialize the sites."
    echo "--destroy     Stop the sites. Destroy all data"
    echo "--help        display this message"
    echo "--restart     Restart all running sites."
    echo "--start       Start all stopped sites."
    echo "--stop        Stop all running sites."

    echo "{folder1}     -folder pointing to first Moodle site (Mandatory)"
    echo "{folder2}     -folder pointing to second Moodle site (optional)"
    echo "{folder3}     -folder pointing to third Moodle site (optional)"
    echo "
        Examples:
            sh k1many.sh --build M405            # Start a site with the folder in docker/M405 folder
            sh k1many.sh --build M405 M401 MT    # Start three sites with based in docker/M405, docker/M401, docker/MT
            sh k1many.sh --start                 # Start all stopped sites
            sh k1many.sh --stop                  # Stop all stopped sites
            sh k1many.sh --destroy               # Stop and destroy sites
        "
}

# Decorator to output information message to the user.
# Takes 1 param, then message to be displayed.
info_message() {
    CYAN='\033[0;36m'
    NC='\033[0m' # No Color
    echo
    echo -e "${CYAN}$1${NC}"
    echo
}

# Decorator to output error message to the user.
# Takes 1 param, then message to be displayed.
error_message() {
    RED='\033[0;31m'
    NC='\033[0m' # No Color
    echo
    echo -e "${RED}$1${NC}"
    echo
}

start_server() {
    # Start the server
    bin/moodle-docker-compose up -d
    # Sleep for 6 seconds to allow database to come up
    #  sleep 6
    # Just in case there is still some latency.
    bin/moodle-docker-wait-for-db
}

start_instances() {
    # xDebug port. Must be different for each instances.
    xdebugport=$1

    # Reset the xDebug config file from previous boot.
    # We reset it to set the client port back 9003 to
    # make sure the sed will find and replace it with
    # the new client port.
    git checkout assets/php/docker-php-ext-xdebug.ini

    # Change xDebug port for this instance.
    sed -i -e 's/xdebug.client_port=9003/xdebug.client_port='"${xdebugport}"'/g' assets/php/docker-php-ext-xdebug.ini

    # Starts the container and wait for DB.
    start_server

    info_message "${folder} site started at http://localhost:${MOODLE_DOCKER_WEB_PORT}"
}

# Function to group the commands to build the each instances.
# The params are validated before this function is called.
build_instances() {
    # Project name (folder that contains the Moodle files)
    projectname=$1

    # Full path of the Moodle folder.
    folder=$2

    # xDebug port. Must be different for each instances.
    xdebugport=$3

    # Reset the xDebug config file from previous boot.
    # We reset it to set the client port back 9003 to
    # make sure the sed will find and replace it with
    # the new client port.
    git checkout assets/php/docker-php-ext-xdebug.ini

    # Change xDebug port for this instance.
    sed -i -e 's/xdebug.client_port=9003/xdebug.client_port='"${xdebugport}"'/g' assets/php/docker-php-ext-xdebug.ini

    # Starts the container and wait for DB.
    start_server

    # Install Moodle.
    bin/moodle-docker-compose exec webserver php admin/cli/install_database.php --agree-license --fullname="${projectname}" --shortname="${projectname}" --summary="${projectname}" --adminpass="test" --adminemail="admin@example.com"

    # Set the session cookie to avoid login problem between instances.
    bin/moodle-docker-compose exec webserver php admin/cli/cfg.php --name=sessioncookie --set="${projectname}"

    # Install xdebug extention in the new webserser.
    # If already installed, the install will just fail.
    bin/moodle-docker-compose exec webserver pecl install xdebug

    # Enable XDebug extension in Apache and restart the webserver container
    bin/moodle-docker-compose exec webserver docker-php-ext-enable xdebug
    bin/moodle-docker-compose restart webserver

    info_message "${folder} site started - http://localhost:${MOODLE_DOCKER_WEB_PORT}"
}

# This function resets all config files used during boot of project.
# Should be used when --destroy containers.
reset_config_files() {
    git checkout local.yml
    git checkout assets/php/docker-php-ext-xdebug.ini
}

exists_in_list() {
    LIST=$1
    DELIMITER=$2
    VALUE=$3
    LIST_WHITESPACES=`echo $LIST | tr "$DELIMITER" " "`
    for x in $LIST_WHITESPACES; do
        if [ "$x" = "$VALUE" ]; then
            return 1
        fi
    done
    return 0
}

validate_folder_path() {
    if [ ! -d "${1}" ]; then
        error_message "${1} is not valid"
        help_messages
        exit 1
    fi
}

##################
### Validation ###
if [ $# -eq 0 ];  then
    error_message "No arguments supplied"
    help_messages
    exit 1
fi

if [ $# -lt 1 ] || [ $# -gt 4 ] ;  then
    error_message "Invalid number of arguments passed in. Must be between 1 and 4 arguments"
    help_messages
    exit 1
fi

list_of_options="--build --destroy --help --reboot --stop --start --restart"
SWITCH=$1
if  exists_in_list "$list_of_options" " " $SWITCH;  then
    error_message "Invalid option $SWITCH."
    help_messages
    exit 1
fi

# Display help message if the --help switch is present.
if [ "$SWITCH" = "--help" ]
then
    help_messages
    exit 0
fi

########################
### Global variables ###
# MOODLE_DOCKER_DB          - database used by Moodle - default maria db
# MOODLE_DOCKER_WWWROOT     - folder where the Moodle code is located;
# MOODLE_DOCKER_PORT        - port (default 8000);
# MOODLE_DOCKER_PHP_VERSION - php version used in Moodle - default 8.1;
# COMPOSE_PROJECT_NAME      - Docker project name - used to identify sites;

# We always use Maria DB for all our Moodle.
export MOODLE_DOCKER_DB=mariadb

# Current working dir.
cwd=$( dirname "$PWD" )

# Moodle Docker Port.
# AKA which port the webserver container will listen to.
moodleDockerPort=(8000 1234 5678)

# xDebug ports
# Each containers must have a their own port.
xdebugPort=(9003 9004 9005)

# Use the multiple instances local.yml file.
cp local.yml_many local.yml

################################################
### Process swithes that don't need options. ###
case $SWITCH in
    "--destroy")
        if ! docker ps | grep -q 'moodlehq'; then
            info_message "No containers running. Nothing to shutdown."
            exit 1
        fi
        docker stop $(docker ps -a -q)
        docker rm $(docker ps -a -q)
        reset_config_files
        info_message "All containers shut down and removed."
        exit 1
        ;;
    "--restart")
        if ! docker ps | grep -q 'moodlehq'; then
            info_message "No containers running. Nothing to reboot."
            exit 1
        fi
        docker restart $(docker ps -q)
        info_message "All sites restarted."
        exit 1
        ;;
    "--stop")
        if ! docker ps | grep -q 'moodlehq'; then
            info_message "No containers running. Nothing to stop."
            exit 1
        fi
        docker stop $(docker ps -q)
        info_message "All sites stopped."
        exit 1
        ;;
esac

#############################################
### Process swithes that require options. ###

# Ignore first parm passed to the script.
# Skip the --switch to cycle the folders in argument.
shift

# Iterate the passed folders.
iteratior=0
for i in "$@"
do
    # Folder passed in args to the script.
    argfolder="$i"

    # Full system path of the Moodle instance.
    validate_folder_path "${cwd}/${argfolder}"
    fullfolderpath="${cwd}/${argfolder}"
    export MOODLE_DOCKER_WWWROOT=${fullfolderpath}

    # Check the Moodle version. If its 4.5 then set php version to 8.3.
    export MOODLE_DOCKER_PHP_VERSION=8.1
    moodlever=$(grep "$branch   = '405';" $fullfolderpath/version.php)
    if [ "$moodlever" ]; then
        export MOODLE_DOCKER_PHP_VERSION=8.3
    fi

    # Used to name the project according to the folder name
    # which makes it easier to recognize who is who in Docker.
    projectname="${argfolder}"
    export COMPOSE_PROJECT_NAME=${projectname}

    case $SWITCH in
        "--build")
            if [ -n "$(docker ps -f "name=${projectname}-webserver-1" -f "status=running" -q )" ]; then
                error_message "The first site is already running! It cannot be re-initialized."
                exit 1
            fi
            export MOODLE_DOCKER_WEB_PORT="${moodleDockerPort[$iteratior]}"
            cp config.docker-template.php $MOODLE_DOCKER_WWWROOT/config.php
            build_instances ${projectname} ${fullfolderpath} "${xdebugPort[$iteratior]}"
            ;;
        "--start")
            export MOODLE_DOCKER_WEB_PORT="${moodleDockerPort[$iteratior]}"
            cp config.docker-template.php $MOODLE_DOCKER_WWWROOT/config.php
            start_instances "${xdebugPort[$iteratior]}"
            ;;
    esac

    # Increment loop counter.
    iteratior=$((iteratior+1))
done
exit 0

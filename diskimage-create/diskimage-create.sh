#!/bin/bash

set -e

export IMAGE_SIZE=$DIB_IMAGE_SIZE
# This will unset parameter DIB_IMAGE_SIZE for Ubuntu and Fedora vanilla images
unset DIB_IMAGE_SIZE

# DEBUG_MODE is set by the -d flag, debug is enabled if the value is "true"
DEBUG_MODE="false"

# The default tag to use for the DIB repo
DEFAULT_DIB_REPO_BRANCH="0.1.29"

# The default version for a MapR plugin
DIB_DEFAULT_MAPR_VERSION="4.0.1"

# Default list of datasource modules for ubuntu. Workaround for bug #1375645
export CLOUD_INIT_DATASOURCES=${DIB_CLOUD_INIT_DATASOURCES:-"NoCloud, ConfigDrive, OVF, MAAS, Ec2"}

usage() {
    echo
    echo "Usage: $(basename $0)"
    echo "         [-p vanilla|spark|hdp|cloudera|storm|mapr]"
    echo "         [-i ubuntu|fedora|centos]"
    echo "         [-v 1|2|2.6|5.0|5.3|plain]"
    echo "         [-r 3.1.1|4.0.1]"
    echo "         [-d]"
    echo "         [-m]"
    echo "         [-u]"
    echo "   '-p' is plugin version (default: all plugins)"
    echo "   '-i' is operating system of the base image (default: all supported by plugin)"
    echo "   '-v' is hadoop version (default: all supported by plugin)"
    echo "   '-r' is MapR Version (default: ${DIB_DEFAULT_MAPR_VERSION})"
    echo "   '-d' enable debug mode, root account will have password 'hadoop'"
    echo "   '-m' set the diskimage-builder repo to the master branch (default: $DEFAULT_DIB_REPO_BRANCH)"
    echo "   '-u' install missing packages necessary for building"
    echo
    echo "You shouldn't specify hadoop version and image type for spark plugin"
    echo "You shouldn't specify image type for hdp plugin"
    echo "Version 'plain' could be specified for hdp plugin only"
    echo "Debug mode should only be enabled for local debugging purposes, not for production systems"
    echo "By default all images for all plugins will be created"
    echo
    exit 1
}

while getopts "p:i:v:dmur:" opt; do
    case $opt in
        p)
            PLUGIN=$OPTARG
        ;;
        i)
            BASE_IMAGE_OS=$OPTARG
        ;;
        v)
            HADOOP_VERSION=$OPTARG
        ;;
        d)
            DEBUG_MODE="true"
        ;;
        m)
            if [ -n "$DIB_REPO_BRANCH" ]; then
                echo "Error: DIB_REPO_BRANCH set and -m requested, please choose one."
                exit 3
            else
                DIB_REPO_BRANCH="master"
            fi
        ;;
        r)
            DIB_MAPR_VERSION=$OPTARG
        ;;
        u)
            DIB_UPDATE_REQUESTED=true
        ;;
        *)
            usage
        ;;
    esac
done

shift $((OPTIND-1))
if [ "$1" ]; then
    usage
fi

if [ -z $DIB_REPO_BRANCH ]; then
    DIB_REPO_BRANCH=$DEFAULT_DIB_REPO_BRANCH
fi

if [ -e /etc/os-release ]; then
    platform=$(head -1 /etc/os-release)
else
    platform=$(head -1 /etc/system-release | grep -e CentOS -e 'Red Hat Enterprise Linux' || :)
    if [ -z "$platform" ]; then
        echo -e "Unknown Host OS. Impossible to build images.\nAborting"
        exit 2
    fi
fi

# Checks of input
if [ "$DEBUG_MODE" = "true" -a "$platform" != 'NAME="Ubuntu"' ]; then
    if [ "$(getenforce)" != "Disabled" ]; then
        echo "Debug mode cannot be used from this platform while SELinux is enabled, see https://bugs.launchpad.net/sahara/+bug/1292614"
        exit 1
    fi
fi

if [ -n "$PLUGIN" -a "$PLUGIN" != "vanilla" -a "$PLUGIN" != "spark" -a "$PLUGIN" != "hdp" -a "$PLUGIN" != "cloudera" -a "$PLUGIN" != "storm" -a "$PLUGIN" != "mapr" ]; then
    echo -e "Unknown plugin selected.\nAborting"
    exit 1
fi

if [ -n "$BASE_IMAGE_OS" -a "$BASE_IMAGE_OS" != "ubuntu" -a "$BASE_IMAGE_OS" != "fedora" -a "$BASE_IMAGE_OS" != "centos" ]; then
    echo -e "Unknown image type selected.\nAborting"
    exit 1
fi

if [ -n "$HADOOP_VERSION" -a "$HADOOP_VERSION" != "1" -a "$HADOOP_VERSION" != "2" -a "$HADOOP_VERSION" != "plain" ]; then
    if [ "$PLUGIN" = "vanilla" -a "$HADOOP_VERSION" != "1" -a "$HADOOP_VERSION" != "2.6" -a "$HADOOP_VERSION" != "plain" ]; then
        if [ "$PLUGIN" = "cloudera" -a "$HADOOP_VERSION" != "5.0" -a "$HADOOP_VERSION" != "5.3" ]; then
            echo -e "Unknown hadoop version selected.\nAborting"
            exit 1
        fi
    fi
fi

if [ "$PLUGIN" = "vanilla" -a "$HADOOP_VERSION" = "plain" ]; then
    echo "Impossible combination.\nAborting"
    exit 1
fi

if [ "$PLUGIN" = "cloudera" -a "$BASE_IMAGE_OS" = "fedora" ]; then
    echo "Impossible combination.\nAborting"
    exit 1
fi

if [ "$PLUGIN" = "mapr" -a "$BASE_IMAGE_OS" = "fedora" ]; then
    echo "'fedora' image type is not supported by 'mapr' plugin.\nAborting"
    exit 1
fi

if [ "$PLUGIN" != "mapr" -a -n "$DIB_MAPR_VERSION" ]; then
    echo "'-r' parameter should be used only with 'mapr' plugin.\nAborting"
    exit 1
fi

if [ "$PLUGIN" = "mapr" -a -z "$DIB_MAPR_VERSION" ]; then
    echo "MapR version is not specified.\n"
    echo "${DIB_DEFAULT_MAPR_VERSION} version would be used.\n"
    DIB_MAPR_VERSION=${DIB_DEFAULT_MAPR_VERSION}
fi

if [ "$PLUGIN" = "mapr" -a "${DIB_MAPR_VERSION}" != "3.1.1" -a "${DIB_MAPR_VERSION}" != "4.0.1" ]; then
    echo "Unknown MapR version.\nExit"
    exit 1
fi

#################

is_installed() {
    if [ "$platform" = 'NAME="Ubuntu"' ]; then
        dpkg -s "$1" &> /dev/null
    else
        # centos, fedora, opensuse, or rhel
        rpm -q "$1" &> /dev/null
    fi
}

need_required_packages() {
    if [[ "$platform" == 'NAME="Ubuntu"' ]]; then
        package_list="qemu kpartx git"
    elif [ "$platform" = 'NAME=Fedora' ]; then
        package_list="qemu-img kpartx git"
    elif [ "$platform" = 'NAME=openSUSE' ]; then
        package_list="qemu kpartx git-core"
    else
        # centos or rhel
        package_list="qemu-kvm qemu-img kpartx git"
        if [ ${platform:0:6} = "CentOS" ]; then
            # CentOS requires the python-argparse package be installed separately
            package_list="$package_list python-argparse"
        fi
    fi

    for p in `echo $package_list`; do
        if ! is_installed $p; then
            return 0
        fi
    done
    return 1
}

if need_required_packages; then
    # install required packages if requested
    if [ -n "$DIB_UPDATE_REQUESTED" ]; then
        if [ "$platform" = 'NAME="Ubuntu"' ]; then
            apt-get install $package_list -y
        elif [ "$platform" = 'NAME=openSUSE' ]; then
            zypper --non-interactive --gpg-auto-import-keys in $package_list
        else
            # fedora, centos,  and rhel share an install command
            if [ ${platform:0:6} = "CentOS" ]; then
                # install EPEL repo, in order to install argparse
                rpm -Uvh --force http://dl.fedoraproject.org/pub/epel/6/x86_64/epel-release-6-8.noarch.rpm
            fi
            yum install $package_list -y
        fi
    else
        echo "Missing one of the following packages: $package_list"
        echo "Please install manually or rerun with the update option (-u)."
        exit 1
    fi
fi

base_dir="$(dirname $(readlink -e $0))"

TEMP=$(mktemp -d diskimage-create.XXXXXX)
pushd $TEMP

export DIB_IMAGE_CACHE=$TEMP/.cache-image-create

# Working with repositories
# disk-image-builder repo

if [ -z $DIB_REPO_PATH ]; then
    git clone https://git.openstack.org/openstack/diskimage-builder
    DIB_REPO_PATH="$(pwd)/diskimage-builder"
    git --git-dir=$DIB_REPO_PATH/.git --work-tree=$DIB_REPO_PATH checkout $DIB_REPO_BRANCH
fi

export PATH=$PATH:$DIB_REPO_PATH/bin

pushd $DIB_REPO_PATH
export DIB_COMMIT_ID=`git rev-parse HEAD`
popd

export ELEMENTS_PATH="$DIB_REPO_PATH/elements"

# sahara-image-elements repo

if [ -z $SIM_REPO_PATH ]; then
    SIM_REPO_PATH="$(dirname $base_dir)"
    if [ $(basename $SIM_REPO_PATH) != "sahara-image-elements" ]; then
        echo "Can't find Sahara-image-elements repository. Cloning it."
        git clone https://git.openstack.org/openstack/sahara-image-elements
        SIM_REPO_PATH="$(pwd)/sahara-image-elements"
    fi
fi

ELEMENTS_PATH=$ELEMENTS_PATH:$SIM_REPO_PATH/elements

pushd $SIM_REPO_PATH
export SAHARA_ELEMENTS_COMMIT_ID=`git rev-parse HEAD`
popd

if [ "$DEBUG_MODE" = "true" ]; then
    echo "Using Image Debug Mode, using root-pwd in images, NOT FOR PRODUCTION USAGE."
    # Each image has a root login, password is "hadoop"
    export DIB_PASSWORD="hadoop"
fi

#############################
# Images for Vanilla plugin #
#############################

if [ -z "$PLUGIN" -o "$PLUGIN" = "vanilla" ]; then
    export JAVA_DOWNLOAD_URL=${JAVA_DOWNLOAD_URL:-"http://download.oracle.com/otn-pub/java/jdk/7u51-b13/jdk-7u51-linux-x64.tar.gz"}
    export OOZIE_HADOOP_V1_DOWNLOAD_URL=${OOZIE_HADOOP_V1_DOWNLOAD_URL:-"http://sahara-files.mirantis.com/oozie-4.0.0.tar.gz"}
    export OOZIE_HADOOP_V2_6_DOWNLOAD_URL=${OOZIE_HADOOP_V2_6_DOWNLOAD_URL:-"http://sahara-files.mirantis.com/oozie-4.0.1-hadoop-2.6.0.tar.gz"}
    export HADOOP_V2_6_NATIVE_LIBS_DOWNLOAD_URL=${HADOOP_V2_6_NATIVE_LIBS_DOWNLOAD_URL:-"http://sahara-files.mirantis.com/hadoop-native-libs-2.6.0.tar.gz"}
    export EXTJS_DOWNLOAD_URL=${EXTJS_DOWNLOAD_URL:-"http://extjs.com/deploy/ext-2.2.zip"}
    export HIVE_VERSION=${HIVE_VERSION:-"0.11.0"}

    ubuntu_elements_sequence="base vm ubuntu hadoop oozie mysql hive"
    fedora_elements_sequence="base vm fedora redhat-lsb hadoop oozie mysql disable-firewall hive updater"
    centos_elements_sequence="vm rhel hadoop oozie mysql redhat-lsb disable-firewall hive updater"

    if [ "$DEBUG_MODE" = "true" ]; then
        ubuntu_elements_sequence="$ubuntu_elements_sequence root-passwd"
        fedora_elements_sequence="$fedora_elements_sequence root-passwd"
        centos_elements_sequence="$centos_elements_sequence root-passwd"
    fi

    # Workaround for https://bugs.launchpad.net/diskimage-builder/+bug/1204824
    # https://bugs.launchpad.net/sahara/+bug/1252684
    if [ "$platform" = 'NAME="Ubuntu"' ]; then
        echo "**************************************************************"
        echo "WARNING: As a workaround for DIB bug 1204824, you are about to"
        echo "         create a Fedora and CentOS images that has SELinux    "
        echo "         disabled. Do not use these images in production.       "
        echo "**************************************************************"
        fedora_elements_sequence="$fedora_elements_sequence selinux-permissive"
        centos_elements_sequence="$centos_elements_sequence selinux-permissive"
        suffix=".selinux-permissive"
    fi

    if [ -n "$USE_MIRRORS" ]; then
        [ -n "$UBUNTU_MIRROR" ] && ubuntu_elements_sequence="$ubuntu_elements_sequence apt-mirror"
        [ -n "$FEDORA_MIRROR" ] && fedora_elements_sequence="$fedora_elements_sequence fedora-mirror"
        [ -n "$CENTOS_MIRROR" ] && centos_elements_sequence="$centos_elements_sequence centos-mirror"
    fi

    # Ubuntu cloud image
    if [ -z "$BASE_IMAGE_OS" -o "$BASE_IMAGE_OS" = "ubuntu" ]; then
        export DIB_CLOUD_INIT_DATASOURCES=$CLOUD_INIT_DATASOURCES

        if [ -z "$HADOOP_VERSION" -o "$HADOOP_VERSION" = "1" ]; then
            export DIB_HADOOP_VERSION=${DIB_HADOOP_VERSION_1:-"1.2.1"}
            export ubuntu_image_name=${ubuntu_vanilla_hadoop_1_image_name:-"ubuntu_sahara_vanilla_hadoop_1_latest"}
            elements_sequence="$ubuntu_elements_sequence swift_hadoop"
            disk-image-create $elements_sequence -o $ubuntu_image_name
            mv $ubuntu_image_name.qcow2 ../
        fi
        if [ -z "$HADOOP_VERSION" -o "$HADOOP_VERSION" = "2.6" ]; then
            export DIB_HADOOP_VERSION=${DIB_HADOOP_VERSION_2_6:-"2.6.0"}
            export ubuntu_image_name=${ubuntu_vanilla_hadoop_2_6_image_name:-"ubuntu_sahara_vanilla_hadoop_2_6_latest"}
            disk-image-create $ubuntu_elements_sequence -o $ubuntu_image_name
            mv $ubuntu_image_name.qcow2 ../
        fi
        unset DIB_CLOUD_INIT_DATASOURCES
    fi

    # Fedora cloud image
    if [ -z "$BASE_IMAGE_OS" -o "$BASE_IMAGE_OS" = "fedora" ]; then
        if [ -z "$HADOOP_VERSION" -o "$HADOOP_VERSION" = "1" ]; then
            export DIB_HADOOP_VERSION=${DIB_HADOOP_VERSION_1:-"1.2.1"}
            export fedora_image_name=${fedora_vanilla_hadoop_1_image_name:-"fedora_sahara_vanilla_hadoop_1_latest$suffix"}
            elements_sequence="$fedora_elements_sequence swift_hadoop"
            disk-image-create $elements_sequence -o $fedora_image_name
            mv $fedora_image_name.qcow2 ../
        fi
        if [ -z "$HADOOP_VERSION" -o "$HADOOP_VERSION" = "2.6" ]; then
            export DIB_HADOOP_VERSION=${DIB_HADOOP_VERSION_2_6:-"2.6.0"}
            export fedora_image_name=${fedora_vanilla_hadoop_2_6_image_name:-"fedora_sahara_vanilla_hadoop_2_6_latest$suffix"}
            disk-image-create $fedora_elements_sequence -o $fedora_image_name
            mv $fedora_image_name.qcow2 ../
        fi
    fi

    # CentOS cloud image:
    # - Disable including 'base' element for CentOS
    # - Export link and filename for CentOS cloud image to download
    if [ -z "$BASE_IMAGE_OS" -o "$BASE_IMAGE_OS" = "centos" ]; then
        # Read Create_CentOS_cloud_image.rst to know how to create CentOS image in qcow2 format
        export BASE_IMAGE_FILE="CentOS-6.6-cloud-init-20141118.qcow2"
        export DIB_CLOUD_IMAGES="http://sahara-files.mirantis.com"
        if [ -z "$HADOOP_VERSION" -o "$HADOOP_VERSION" = "1" ]; then
            export DIB_HADOOP_VERSION=${DIB_HADOOP_VERSION_1:-"1.2.1"}
            export centos_image_name=${centos_vanilla_hadoop_1_image_name:-"centos_sahara_vanilla_hadoop_1_latest$suffix"}
            elements_sequence="$centos_elements_sequence swift_hadoop"
            disk-image-create $elements_sequence -n -o $centos_image_name
            mv $centos_image_name.qcow2 ../
        fi
        if [ -z "$HADOOP_VERSION" -o "$HADOOP_VERSION" = "2.6" ]; then
            export DIB_HADOOP_VERSION=${DIB_HADOOP_VERSION_2_6:-"2.6.0"}
            export centos_image_name=${centos_vanilla_hadoop_2_6_image_name:-"centos_sahara_vanilla_hadoop_2_6_latest$suffix"}
            disk-image-create $centos_elements_sequence -n -o $centos_image_name
            mv $centos_image_name.qcow2 ../
        fi
        unset BASE_IMAGE_FILE DIB_CLOUD_IMAGES
    fi
fi

##########################
# Image for Spark plugin #
##########################

if [ -z "$PLUGIN" -o "$PLUGIN" = "spark" ]; then
    export DIB_HDFS_LIB_DIR="/usr/lib/hadoop"
    export DIB_CLOUD_INIT_DATASOURCES=$CLOUD_INIT_DATASOURCES

    # Ignoring image type and hadoop version options
    echo "For spark plugin options -i and -v are ignored"

    # (Un)comment the following for cdh4 OLD Spark images
    #export DIB_HADOOP_VERSION="CDH4"
    #export JAVA_DOWNLOAD_URL=${JAVA_DOWNLOAD_URL:-"http://download.oracle.com/otn-pub/java/jdk/7u51-b13/jdk-7u51-linux-x64.tar.gz"}
    #ubuntu_elements_sequence="base vm ubuntu java hadoop-cdh spark"

    # (Un)comment the following for cdh5 Spark images
    export DIB_HADOOP_VERSION="CDH5"
    # Tell the cloudera element to install only hdfs
    export SPARK_STANDALONE=1
    export ubuntu_image_name=${ubuntu_spark_image_name:-"ubuntu_sahara_spark_latest"}

    ubuntu_elements_sequence="base vm ubuntu java hadoop-cloudera swift_hadoop spark"

    if [ -n "$USE_MIRRORS" ]; then
        [ -n "$UBUNTU_MIRROR" ] && ubuntu_elements_sequence="$ubuntu_elements_sequence apt-mirror"
    fi

    # Creating Ubuntu cloud image
    disk-image-create $ubuntu_elements_sequence -o $ubuntu_image_name
    mv $ubuntu_image_name.qcow2 ../
    unset DIB_CLOUD_INIT_DATASOURCES
    unset DIB_HDFS_LIB_DIR
fi


##########################
# Image for Storm plugin #
##########################

if [ -z "$PLUGIN" -o "$PLUGIN" = "storm" ]; then
    export DIB_CLOUD_INIT_DATASOURCES=$CLOUD_INIT_DATASOURCES

    # Ignoring image type and hadoop version options
    echo "For storm plugin options -i and -v are ignored"

    export JAVA_DOWNLOAD_URL=${JAVA_DOWNLOAD_URL:-"http://download.oracle.com/otn-pub/java/jdk/7u51-b13/jdk-7u51-linux-x64.tar.gz"}
    export DIB_STORM_VERSION=${DIB_STORM_VERSION:-0.9.1}
    export ubuntu_image_name=${ubuntu_storm_image_name:-"ubuntu_sahara_storm_latest_$DIB_STORM_VERSION"}

    ubuntu_elements_sequence="base vm ubuntu java zookeeper storm"

    if [ -n "$USE_MIRRORS" ]; then
        [ -n "$UBUNTU_MIRROR" ] && ubuntu_elements_sequence="$ubuntu_elements_sequence apt-mirror"
    fi

    # Creating Ubuntu cloud image
    disk-image-create $ubuntu_elements_sequence -o $ubuntu_image_name
    mv $ubuntu_image_name.qcow2 ../
    unset DIB_CLOUD_INIT_DATASOURCES
fi
#########################
# Images for HDP plugin #
#########################

if [ -z "$PLUGIN" -o "$PLUGIN" = "hdp" ]; then
    echo "For hdp plugin option -i is ignored"

    # Generate HDP images

    # Parameter 'DIB_IMAGE_SIZE' should be specified for CentOS only
    export DIB_IMAGE_SIZE=${IMAGE_SIZE:-"10"}

    # CentOS cloud image:
    # - Disable including 'base' element for CentOS
    # - Export link and filename for CentOS cloud image to download
    export BASE_IMAGE_FILE="CentOS-6.6-cloud-init-20141118.qcow2"
    export DIB_CLOUD_IMAGES="http://sahara-files.mirantis.com"

    # Setup Java Install configuration for the HDP images
    export JAVA_TARGET_LOCATION=/opt
    export JAVA_DOWNLOAD_URL=https://s3.amazonaws.com/public-repo-1.hortonworks.com/ARTIFACTS/jdk-6u31-linux-x64.bin

    # Ignoring image type option
    if [ -z "$HADOOP_VERSION" -o "$HADOOP_VERSION" = "1" ]; then
        export centos_image_name_hdp_1_3=${centos_hdp_hadoop_1_image_name:-"centos-6_5-64-hdp-1-3"}
        # Elements to include in an HDP-based image
        centos_elements_sequence="vm rhel hadoop-hdp redhat-lsb yum updater"
        if [ "$DEBUG_MODE" = "true" ]; then
            # enable the root-pwd element, for simpler local debugging of images
            centos_elements_sequence=$centos_elements_sequence" root-passwd"
        fi

        if [ -n "$USE_MIRRORS"]; then
            [ -n "$CENTOS_MIRROR" ] && centos_elements_sequence="$centos_elements_sequence centos-mirror"
        fi

        # generate image with HDP 1.3
        export DIB_HDP_VERSION="1.3"
        disk-image-create $centos_elements_sequence -n -o $centos_image_name_hdp_1_3
        mv $centos_image_name_hdp_1_3.qcow2 ../
    fi

    if [ -z "$HADOOP_VERSION" -o "$HADOOP_VERSION" = "2" ]; then
        export centos_image_name_hdp_2_0=${centos_hdp_hadoop_2_image_name:-"centos-6_5-64-hdp-2-0"}
        # Elements to include in an HDP-based image
        centos_elements_sequence="vm rhel hadoop-hdp redhat-lsb yum updater"
        if    [ "$DEBUG_MODE" = "true" ]; then
            # enable the root-pwd element, for simpler local debugging of images
            centos_elements_sequence=$centos_elements_sequence" root-passwd"
        fi

        if [ -n "$USE_MIRRORS"]; then
            [ -n "$CENTOS_MIRROR" ] && centos_elements_sequence="$centos_elements_sequence centos-mirror"
        fi

        # generate image with HDP 2.0
        export DIB_HDP_VERSION="2.0"
        disk-image-create $centos_elements_sequence -n -o $centos_image_name_hdp_2_0
        mv $centos_image_name_hdp_2_0.qcow2 ../
    fi

    if [ -z "$HADOOP_VERSION" -o "$HADOOP_VERSION" = "plain" ]; then
        export centos_image_name_plain=${centos_hdp_plain_image_name:-"centos-6_5-64-plain"}
        # Elements for a plain CentOS image that does not contain HDP or Apache Hadoop
        centos_plain_elements_sequence="vm rhel redhat-lsb disable-firewall disable-selinux ssh sahara-version yum"
        if [ "$DEBUG_MODE" = "true" ]; then
            # enable the root-pwd element, for simpler local debugging of images
            centos_plain_elements_sequence=$centos_plain_elements_sequence" root-passwd"
        fi

        if [ -n "$USE_MIRRORS"]; then
            [ -n "$CENTOS_MIRROR" ] && centos_plain_elements_sequence="$centos_plain_elements_sequence centos-mirror"
        fi

        # generate plain (no Hadoop components) image for testing
        disk-image-create $centos_plain_elements_sequence -n -o $centos_image_name_plain
        mv $centos_image_name_plain.qcow2 ../
    fi
    unset BASE_IMAGE_FILE DIB_IMAGE_SIZE DIB_CLOUD_IMAGES
fi

#########################
# Images for CDH plugin #
#########################

if [ -z "$PLUGIN" -o "$PLUGIN" = "cloudera" ]; then
    export EXTJS_DOWNLOAD_URL=${EXTJS_DOWNLOAD_URL:-"http://extjs.com/deploy/ext-2.2.zip"}
    if [ -z "$BASE_IMAGE_OS" -o "$BASE_IMAGE_OS" = "ubuntu" ]; then
        if [ -z "$HADOOP_VERSION" -o "$HADOOP_VERSION" = "5.0" ]; then
            cloudera_5_0_ubuntu_image_name=${cloudera_5_0_ubuntu_image_name:-ubuntu_sahara_cloudera_5_0_0}
            cloudera_elements_sequence="base vm ubuntu hadoop-cloudera"

            if [ -n "$USE_MIRRORS" ]; then
                [ -n "$UBUNTU_MIRROR" ] && ubuntu_elements_sequence="$ubuntu_elements_sequence apt-mirror"
            fi

            # Cloudera supports only 12.04 Ubuntu
            export DIB_CDH_VERSION="5.0"
            export DIB_RELEASE="precise"
            disk-image-create $cloudera_elements_sequence -o $cloudera_5_0_ubuntu_image_name
            mv $cloudera_5_0_ubuntu_image_name.qcow2 ../
            unset DIB_CDH_VERSION DIB_RELEASE
        fi
        if [ -z "$HADOOP_VERSION" -o "$HADOOP_VERSION" = "5.3" ]; then
            cloudera_5_3_ubuntu_image_name=${cloudera_5_3_ubuntu_image_name:-ubuntu_sahara_cloudera_5_3_0}
            cloudera_elements_sequence="base vm ubuntu hadoop-cloudera"

            if [ -n "$USE_MIRRORS" ]; then
                [ -n "$UBUNTU_MIRROR" ] && ubuntu_elements_sequence="$ubuntu_elements_sequence apt-mirror"
            fi

            # Cloudera supports only 12.04 Ubuntu
            export DIB_CDH_VERSION="5.3"
            export DIB_RELEASE="precise"
            disk-image-create $cloudera_elements_sequence -o $cloudera_5_3_ubuntu_image_name
            mv $cloudera_5_3_ubuntu_image_name.qcow2 ../
            unset DIB_CDH_VERSION DIB_RELEASE
        fi
    fi

    if [ -z "$BASE_IMAGE_OS" -o "$BASE_IMAGE_OS" = "centos" ]; then
        if [ -z "$HADOOP_VERSION" -o "$HADOOP_VERSION" = "5.0" ]; then
            # CentOS cloud image:
            # - Disable including 'base' element for CentOS
            # - Export link and filename for CentOS cloud image to download
            export BASE_IMAGE_FILE="CentOS-6.6-cloud-init-20141118.qcow2"
            export DIB_CLOUD_IMAGES="http://sahara-files.mirantis.com"
            export DIB_CDH_VERSION="5.0"

            cloudera_5_0_centos_image_name=${cloudera_5_0_centos_image_name:-centos_sahara_cloudera_5_0_0}
            cloudera_elements_sequence="base vm rhel hadoop-cloudera redhat-lsb selinux-permissive disable-firewall"

            if [ -n "$USE_MIRRORS"]; then
                [ -n "$CENTOS_MIRROR" ] && cloudera_elements_sequence="$cloudera_elements_sequence centos-mirror"
            fi

            disk-image-create $cloudera_elements_sequence -n -o $cloudera_5_0_centos_image_name
            mv $cloudera_5_0_centos_image_name.qcow2 ../

            unset BASE_IMAGE_FILE DIB_CLOUD_IMAGES DIB_CDH_VERSION
        fi
        if [ -z "$HADOOP_VERSION" -o "$HADOOP_VERSION" = "5.3" ]; then
            # CentOS cloud image:
            # - Disable including 'base' element for CentOS
            # - Export link and filename for CentOS cloud image to download
            export BASE_IMAGE_FILE="CentOS-6.6-cloud-init-20141118.qcow2"
            export DIB_CLOUD_IMAGES="http://sahara-files.mirantis.com"
            export DIB_CDH_VERSION="5.3"

            cloudera_5_3_centos_image_name=${cloudera_5_3_centos_image_name:-centos_sahara_cloudera_5_3_0}
            cloudera_elements_sequence="base vm rhel hadoop-cloudera redhat-lsb selinux-permissive disable-firewall"

            if [ -n "$USE_MIRRORS"]; then
                [ -n "$CENTOS_MIRROR" ] && cloudera_elements_sequence="$cloudera_elements_sequence centos-mirror"
            fi

            disk-image-create $cloudera_elements_sequence -n -o $cloudera_5_3_centos_image_name
            mv $cloudera_5_3_centos_image_name.qcow2 ../

            unset BASE_IMAGE_FILE DIB_CLOUD_IMAGES DIB_CDH_VERSION
        fi
    fi
    unset EXTJS_DOWNLOAD_URL
fi

##########################
# Images for MapR plugin #
##########################
if [ -z "$PLUGIN" -o "$PLUGIN" = "mapr" ]; then
    echo "For mapr plugin option -v is ignored"
    export DIB_MAPR_VERSION=${DIB_MAPR_VERSION:-4.0.1}

    export DIB_CLOUD_INIT_DATASOURCES=$CLOUD_INIT_DATASOURCES

    export DIB_IMAGE_SIZE=${IMAGE_SIZE:-"10"}
    #MapR repository requires additional space
    export DIB_MIN_TMPFS=10

    export JAVA_DOWNLOAD_URL=${JAVA_DOWNLOAD_URL:-"http://download.oracle.com/otn-pub/java/jdk/7u51-b13/jdk-7u51-linux-x64.tar.gz"}

    mapr_ubuntu_elements_sequence="base vm ssh ubuntu hadoop-mapr"
    mapr_centos_elements_sequence="base vm rhel ssh hadoop-mapr redhat-lsb selinux-permissive updater disable-firewall"

    if [ "$DEBUG_MODE" = "true" ]; then
        mapr_ubuntu_elements_sequence="$mapr_ubuntu_elements_sequence root-passwd"
        mapr_centos_elements_sequence="$mapr_centos_elements_sequence root-passwd"
    fi

    if [ -n "$USE_MIRRORS" ]; then
        [ -n "$UBUNTU_MIRROR" ] && ubuntu_elements_sequence="$mapr_ubuntu_elements_sequence apt-mirror"
        [ -n "$CENTOS_MIRROR" ] && centos_elements_sequence="$mapr_centos_elements_sequence centos-mirror"
    fi

    if [ -z "$BASE_IMAGE_OS" -o "$BASE_IMAGE_OS" = "ubuntu" ]; then
        export DIB_RELEASE=${DIB_RELEASE:-trusty}

        mapr_ubuntu_image_name=${mapr_ubuntu_image_name:-ubuntu_${DIB_RELEASE}_mapr_${DIB_MAPR_VERSION}_latest}

        disk-image-create $mapr_ubuntu_elements_sequence -n -o $mapr_ubuntu_image_name
        mv $mapr_ubuntu_image_name.qcow2 ../

        unset DIB_RELEASE
    fi

    if [ -z "$BASE_IMAGE_OS" -o "$BASE_IMAGE_OS" = "centos" ]; then
        export BASE_IMAGE_FILE=${BASE_IMAGE_FILE:-"CentOS-6.6-cloud-init-20141118.qcow2"}
        export DIB_CLOUD_IMAGES=${DIB_CLOUD_IMAGES:-"http://sahara-files.mirantis.com"}

        mapr_centos_image_name=${mapr_centos_image_name:-centos_6.5_mapr_${DIB_MAPR_VERSION}_latest}

        disk-image-create $mapr_centos_elements_sequence -n -o $mapr_centos_image_name
        mv $mapr_centos_image_name.qcow2 ../

        unset BASE_IMAGE_FILE DIB_CLOUD_IMAGES
        unset DIB_CLOUD_INIT_DATASOURCES
    fi
fi

popd # out of $TEMP
rm -rf $TEMP

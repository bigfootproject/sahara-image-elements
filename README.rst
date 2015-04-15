Sahara image elements project (Spark experimental fork)
=======================================================

This repo is a place for Sahara-related for diskimage-builder elements.

This has been forked from the OpenStack repository to develop the Spark support in Sahara. The images created with this version of the DIB,
should be used together with the Sahara version available here: https://github.com/bigfootproject/sahara

Images for Spark are created using CDH HDFS and a precompiled Spark from the Apache repositories.

For images for all the other Sahara plugin use the standard Sahara DIB.

You should only need to run this command:

.. sourcecode:: bash

    sudo bash diskimage-create.sh -p spark

Note: More information about script `diskimage-create <https://github.com/openstack/sahara-image-elements/blob/master/diskimage-create/README.rst>`_

This research work is part of the Bigfoot project: http://bigfootproject.eu/

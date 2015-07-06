=====
spark
=====

Installs Spark on Ubuntu. Requires Hadoop CDH 5 (``hadoop-cloudera`` element).

It will install a version of Spark known to be compatible with CDH 5;
this behaviour can be controlled by using ``SPARK_DOWNLOAD_URL`` to specify
a download URL for a pre-built Spark tar.gz file, for example for a
different Spark version. See http://spark.apache.org/downloads.html for more
download options.

Environment Variables
---------------------

DIB_SPARK_VERSION
  :Required: Yes, if ``SPARK_DOWNLOAD_URL`` is not set.
  :Description: Version of the Spark package to download.
  :Exmaple: ``DIB_SPARK_VERSION=1.3.1``

DIB_CDH_VERSION
  :Required: Yes, if ``SPARK_DOWNLOAD_URL`` is not set.
  :Description: Version of the CDH platform to use for Hadoop compatibility.
    CDH version 5.3 is known to work well.
  :Example: ``DIB_CDH_VERSION=5.3``

SPARK_DOWNLOAD_URL
  :Required: No, if set overrides ``DIB_CDH_VERSION`` and ``DIB_SPARK_VERSION``
  :Description: Download URL of a tgz Spark package to override the automatic
    selection from the Apache repositories.

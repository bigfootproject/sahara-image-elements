==========
hadoop-cdh
==========

Installs Hadoop CDH 4 (the Cloudera distribution), configures SSH.
Only HDFS is installed at this time.


Environment Variables
---------------------

DIB_CDH_VERSION
  :Required: Yes, if ``SPARK_DOWNLOAD_URL`` is not set.
  :Description: Version of the CDH platform to use for Hadoop compatibility.
    CDH version 5.3 is known to work well.
  :Example: ``DIB_CDH_VERSION=CDH4``

SPARK_DOWNLOAD_URL
  :Required: No, if set overrides ``DIB_CDH_VERSION`` and ``DIB_SPARK_VERSION``
  :Description: Download URL of a tgz Spark package to override the automatic
    selection from the Apache repositories.

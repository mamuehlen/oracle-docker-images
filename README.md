# Docker Images from Oracle

This repository contains [Dockerfiles](https://docs.docker.com/engine/reference/builder/)
and samples to build [Docker](https://www.docker.com/what-docker) images for
Oracle commercial products and [Oracle sponsored open source projects](https://opensource.oracle.com).

## ZEDAS fork (this branch, `zedas-patches`)

This is ZEDAS' internal fork of Oracle's upstream repository. `main` stays a
clean, unmodified mirror of `oracle/docker-images` - everything ZEDAS-specific
lives exclusively on `zedas-patches`, under
[`OracleDatabase/SingleInstance/extensions/`](OracleDatabase/SingleInstance/extensions/):

- **[`extensions/patching`](OracleDatabase/SingleInstance/extensions/patching/README.md)**:
  bakes a Release Update (RU) into the 19c image at build time and
  regenerates the dbca seed template at that patched level, so containers
  skip the ~30 min `datapatch` run that would otherwise happen on every
  first start. (Not needed for 23.26/26ai Gold Images, which already ship
  pre-patched - see the README.)
- **[`extensions/faststart`](OracleDatabase/SingleInstance/extensions/patching/README.md#faststart-ci-variant-implemented-faststart)**:
  ships a fully pre-created database - both `AL32UTF8` and `WE8ISO8859P15`
  character-set variants baked in, selected at container start - skipping
  `dbca -createDatabase` entirely (~11-22x faster container start than the
  regular image, measured against both 19.32 SE2 and 23.26 SE2). Also
  supports persistence and forward `datapatch` against a mounted volume, see
  the same README's "Persistence and datapatch" section.

Why: fast, disposable, pre-patched Oracle DB containers for ASSET/cargo
CI and local dev, without paying the regular image's patch/seed-creation
cost on every single container start. Built and pushed via the
[`build-and-push.yml`](.github/workflows/build-and-push.yml) GitHub Actions
workflow - see [`CI.md`](CI.md) for how to trigger it and example inputs.

## Container Images on GitHub

These images will require you to download any required Oracle commercial
software before installation. If you want commercial software downloaded for you,
 view [Pre-Built Images with Commercial Software](#pre-built-images-with-commercial-software).

### Oracle Commercial Products

- [Oracle Access Management](/OracleAccessManagement)
- [Oracle BI](/OracleBI)
- [Oracle Cloud Infrastructure Tools](/OracleCloudInfrastructure)
- [Oracle Coherence](/OracleCoherence)
- [Oracle Database](/OracleDatabase)
- [Oracle Essbase](/OracleEssbase)
- [Oracle FMW Infrastructure](/OracleFMWInfrastructure)
- [Oracle GoldenGate](/OracleGoldenGate)
- [Oracle HTTP Server](/OracleHTTPServer)
- [Oracle Identity Governance](/OracleIdentityGovernance)
- [Oracle Instant Client](/OracleInstantClient) (Basic, SDK and SQL*Plus)
- [Oracle Java](/OracleJava)
- [Oracle Rest Data Services](OracleRestDataServices) (ORDS)
- [Oracle SOA Suite](/OracleSOASuite)
- [Oracle Tuxedo](/OracleTuxedo)
- [Oracle Unified Directory](/OracleUnifiedDirectory)
- [Oracle Unified Directory Service Manager](/OracleUnifiedDirectorySM)
- [Oracle WebLogic Server](/OracleWebLogic)
- [Oracle WebCenter Content](/OracleWebCenterContent)
- [Oracle WebCenter Portal](/OracleWebCenterPortal)
- [Oracle WebCenter Sites](/OracleWebCenterSites)

### Oracle Sponsored Open Source Projects

- [GraalVM CE](https://github.com/graalvm/container/tree/master/community)
- [MySQL](https://github.com/mysql/mysql-docker)
- [Oracle OpenJDK](/OracleOpenJDK)
- [Oracle NoSQL Database](/NoSQL)
- [Oracle Linux](https://github.com/oracle/container-images)

### Community Contributions

- [Oracle Forms and Reports](https://github.com/oracle/docker-images/issues/212)
- [Oracle Unified Directory](Contrib/OracleUnifiedDirectory/)

### Archived Projects

- [ContainerCloud](/Archive/ContainerCloud)
- [Oracle Data Integrator](/Archive/OracleDataIntegrator)
- [Oracle Enterprise Data Quality](/Archive/OracleEDQ)
- [Oracle TSAM Plus](/Archive/OracleTuxedo/tsam)

## Pre-Built Images with Commercial Software

These sources already contain Oracle commercial software and require license
acceptance prior to download:

- [Oracle Container Registry](https://container-registry.oracle.com)

## Support

For support and certification information, please consult the documentation
for each product.

For support, bug reporting and feedback about the provided Dockerfiles, please
open an [issue on GitHub](https://github.com/oracle/docker-images/issues).

If you need general support with running containers on Oracle Linux, you can submit
a question under the [Containers and Orchestration](https://community.oracle.com/tech/apps-infra/categories/containers-and-orchestration)
category of the Applications and Infrastructure Community of Oracle Communities.

## Contributing

This project welcomes contributions from the community. Before submitting a pull request, please [review our contribution guide](./CONTRIBUTING.md)

## Security

Please consult the [security guide](./SECURITY.md) for our responsible security vulnerability disclosure process

## License

Copyright (c) 2019, 2023 Oracle and/or its affiliates.

Released under the Universal Permissive License v1.0 as shown at
<https://oss.oracle.com/licenses/upl/>.

# NAME

Devel::Analzye - Analyze a source tree and store state to a SQLite database

# DESCRIPTION

Analyzes one or more directories of files looking for Perl and bash
scripts. An inventory of files along with certain attributes are
stored to a SQLite database. Optionally Perl dependencies and their
versions and a `perlcritic` anlysis can be performed.

# USAGE

perl-analyzer \[options\] command args

## Options

- --core, -c, --nocore
- --database, -D
- --dryrun, -d
- --filter, -f
- --force, -f
- --ignore, -i
- --limit, -l
- --log-level, -L

## Commands

### clear

Delete all records from one of the tables. If you clear the `file`
table, all tables will be cleared.

- Arguments
    - table

        Name of the table to clear. Valid values are `file`, `dependencies`,
        `critic`.

### create-database

### update

- Arguments
    - inventory
    - require

# VERSION

perl-analyzer 0.1

# AUTHOR

Rob Lauer - <bigfoot@cpan.org>

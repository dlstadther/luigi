Release Process
===============

For maintainers of Luigi who have push access to PyPI.

Prerequisites
-------------

- `uv <https://github.com/astral-sh/uv>`_ — Python package manager (build & publish)
- `gh <https://cli.github.com>`_ — GitHub CLI (PR creation, release tagging)
- A PyPI API token with upload permissions for the ``luigi`` package

Workflow
--------

The release process uses three commands with a manual step after the first.

Step 1: Prepare the release
~~~~~~~~~~~~~~~~~~~~~~~~~~~~

From an up-to-date ``master`` branch with a clean working tree::

    make release-prepare BUMP=<patch|minor|major>

This will:

1. Validate prerequisites (correct branch, clean tree, tools installed)
2. Compute the next version number
3. Create a ``release/x.y.z`` branch
4. Update ``luigi/__version__.py``
5. Commit with the message ``Version x.y.z``
6. Push the branch and open a PR against ``master``

To push to a remote other than ``origin``::

    make release-prepare BUMP=minor REMOTE=upstream

Step 2: Merge (manual)
~~~~~~~~~~~~~~~~~~~~~~~

1. Review the PR and wait for CI to pass.
2. Merge the PR into ``master``.

Step 3: Create a GitHub Release
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

From an up-to-date ``master`` branch after merging the PR::

    make release-tag

This will:

1. Pull the latest ``master`` and fetch tags
2. Read the version from ``luigi/__version__.py``
3. Create a GitHub Release with a bare version tag (e.g., ``3.9.0``) and auto-generated release notes

Step 4: Publish to PyPI
~~~~~~~~~~~~~~~~~~~~~~~~

Set your PyPI token and publish::

    export UV_PUBLISH_TOKEN="your-pypi-token"
    make release-publish

This will:

1. Fetch the latest tags and pull ``master``
2. Validate: clean working tree, on ``master``, tag exists, version matches, not already on PyPI
3. Build the package
4. Show a summary and ask for confirmation
5. Upload to PyPI

To skip the confirmation prompt (e.g., for scripted use)::

    make release-publish FORCE=1

To retry a partially failed upload::

    FORCE=1 make release-publish

Conventions
-----------

- **Tags:** Bare version numbers (e.g., ``3.9.0``), no ``v`` prefix
- **Release branches:** ``release/x.y.z``
- **Commit message:** ``Version x.y.z``

Environment Variables
---------------------

``UV_PUBLISH_TOKEN``
    PyPI API token for uploading. Required for ``release-publish``.

``REMOTE``
    Git remote to push to during ``release-prepare``. Default: ``origin``.

``FORCE``
    Set to ``1`` to skip the PyPI existence check and the confirmation prompt.
    Useful for retrying a partially failed upload.

Troubleshooting
---------------

**Branch already exists:**
    If ``release/x.y.z`` already exists from a previous attempt, delete it::

        git branch -D release/x.y.z            # local
        git push origin --delete release/x.y.z  # remote

**Tag not found during publish:**
    Ensure you created a GitHub Release with the bare version tag (no ``v`` prefix).
    The script fetches tags automatically, but if the tag still isn't found, try::

        git fetch --tags

**Version already on PyPI:**
    If a previous upload partially succeeded, use ``FORCE=1`` to skip the check.
    Note that PyPI does not allow re-uploading a version that has been fully published.

Versioning
----------

Luigi is not released on a fixed schedule. When possible, follow semantic
versioning: bump major for incompatible API changes, minor for new backwards-compatible
functionality, and patch for backwards-compatible bug fixes.

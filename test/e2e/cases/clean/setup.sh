git init -q .
git add -A
printf ordinary-result > result
mkdir -p nested result-analysis
printf nested-keep > nested/keep.txt
printf valuable > result-analysis/valuable.txt
printf linked-target > valuable.txt
ln -s valuable.txt result-unrelated
git_bin=$(command -v git)
store_target=${git_bin%/bin/git}
ln -s "$store_target" result-docs
ln -s "$store_target/share/git-core/templates/description" nix-target-survives
ln -s /nix/store/pagda-clean-missing-target result-dangling
ln -s "$store_target/share/git-core/templates/description" result-nested

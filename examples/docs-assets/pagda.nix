{ pkgs, pagda }:
{
  meta.description = "Example pagda project: literate docs with a folded-in diagram";

  docs = pagda.docBackends.enhancedHtml { entryModule = "Demo"; };

  # Fold the diagram into the docs output; Demo.lagda.md references it.
  docsAssets."architecture.svg" = ./architecture.svg;
}

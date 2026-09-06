/**
 * Counts extracted syntax and compiler errors per repository Swift file.
 * This evidence query does not detect vulnerabilities or suppress findings.
 */
import swift

from File file
where file.getExtension() = "swift" and exists(file.getRelativePath())
select file.getRelativePath(), count(AstNode node | node.getFile() = file),
  count(CompilerError error | error.getFile() = file)

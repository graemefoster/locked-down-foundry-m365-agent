param deploy bool = false

module testMod 'test-target.bicep' = if (deploy) {
  name: 'test'
}

output testOut string = deploy ? (testMod.?outputs.?myOut ?? '') : 'nothing'

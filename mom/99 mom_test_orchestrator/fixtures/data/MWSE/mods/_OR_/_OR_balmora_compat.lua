local eightPlates = {
  { cellName = 'Balmora, Eight Plates' },
}

return {
  objectToReplace1 = {
    oldObject = 'furn_de_tapestry_04',
    newObjects = {
      newObject1 = {
        newObject = 'furn_de_tapestry_03',
        replaceChance = 1,
        specificCell = eightPlates,
      },
    },
  },
  objectToReplace2 = {
    oldObject = 'furn_de_rug_01',
    newObjects = {
      newObject1 = {
        newObject = 'furn_de_rug_02',
        replaceChance = 1,
        specificCell = eightPlates,
      },
      newObject2 = {
        newObject = 'furn_de_rug_big_01',
        replaceChance = 1,
        excludedCell = eightPlates,
      },
    },
  },
}

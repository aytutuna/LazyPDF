package com.lazypdf.lazypdf

import org.junit.Assert.assertEquals
import org.junit.Test

class PackageTest {
    @Test
    fun theActivityLivesInTheApplicationPackage() {
        assertEquals("com.lazypdf.lazypdf.MainActivity", MainActivity::class.java.name)
    }
}

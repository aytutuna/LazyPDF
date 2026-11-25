import Foundation

// Follows ViewScale of windows/LazyPDF.App/Tools/EditContent/EditSurface.Chrome.cs.

public enum ViewScale {
    /// View points in one point of the page for `pageToView`. Rotated a quarter turn m11 is 0, so this takes the length of
    /// the first column, which is the same at any rotation.
    public static func of(_ matrix: ViewMatrix) -> Double {
        (matrix.m11 * matrix.m11 + matrix.m12 * matrix.m12).squareRoot()
    }
}

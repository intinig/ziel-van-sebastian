import Foundation

/// The happy-Mac face on its authentic pixel grid, locked during design.
/// Small 2×5 eyes, long J-nose starting at eye level hooking LEFT,
/// thin smile with stepped upturned corners. Uniform stroke weight.
public enum FaceGeometry {
    public struct PixelRect: Equatable {
        public let x, y, w, h: Int
        public init(x: Int, y: Int, w: Int, h: Int) {
            self.x = x; self.y = y; self.w = w; self.h = h
        }
    }

    public static let gridWidth = 19
    public static let gridHeight = 16

    public static let leftEye     = PixelRect(x: 0,  y: 0,  w: 2,  h: 5)
    public static let rightEye    = PixelRect(x: 17, y: 0,  w: 2,  h: 5)
    public static let noseBar     = PixelRect(x: 9,  y: 0,  w: 2,  h: 11)
    public static let noseFoot    = PixelRect(x: 6,  y: 9,  w: 3,  h: 2)
    public static let smileLeft   = PixelRect(x: 2,  y: 12, w: 2,  h: 2)
    public static let smileBottom = PixelRect(x: 4,  y: 14, w: 11, h: 2)
    public static let smileRight  = PixelRect(x: 15, y: 12, w: 2,  h: 2)

    public static let all: [PixelRect] = [leftEye, rightEye, noseBar, noseFoot, smileLeft, smileBottom, smileRight]
    public static let eyes: [PixelRect] = [leftEye, rightEye]
}

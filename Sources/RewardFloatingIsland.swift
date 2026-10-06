import AppKit
import SceneKit

/// The island is derived from the same plot bounds as the buildable board, including
/// its one-ring expansion frontier. Nothing here changes ownership or saved cells.
struct RewardIslandLayout {
    let width: CGFloat
    let depth: CGFloat
    let centerX: CGFloat
    let centerZ: CGFloat
    var rockDepth: CGFloat { min(30, max(8, sqrt(width * depth) * 0.56)) }
    var overviewScale: Double { max(20, Double((width + depth) * 0.43 + rockDepth * 0.5 + 4)) }

    init(minRow: Int, maxRow: Int, minColumn: Int, maxColumn: Int,
         subdivisions: Int = 3, microDimension: Int = 21) {
        width = CGFloat((maxColumn - minColumn + 1) * subdivisions) + 3.2
        depth = CGFloat((maxRow - minRow + 1) * subdivisions) + 3.2
        centerX = CGFloat(minColumn + maxColumn) * CGFloat(subdivisions) / 2 - CGFloat(microDimension - 1) / 2 + 1
        centerZ = CGFloat(minRow + maxRow) * CGFloat(subdivisions) / 2 - CGFloat(microDimension - 1) / 2 + 1
    }
}

enum RewardFloatingIsland {
    static func make(layout: RewardIslandLayout, rock: NSImage?, grass: NSImage?) -> SCNNode {
        let root = SCNNode(); root.name = "floating-island"
        root.position = SCNVector3(layout.centerX, 0, layout.centerZ)
        let count = 96
        let outline = (0..<count).map { index -> SIMD2<Double> in
            let angle = Double(index) * .pi * 2 / Double(count)
            let direction = SIMD2(cos(angle), sin(angle))
            let half = SIMD2(Double(layout.width/2), Double(layout.depth/2))
            let radius = 1.4
            // Ray intersection with a rounded rectangle, preserving coverage at corners.
            var low = 0.0, high = simd_length(half)
            for _ in 0..<18 {
                let mid = (low + high)/2
                let p = simd_abs(direction * mid) - (half - SIMD2(repeating:radius))
                let outside = simd_max(p, SIMD2(repeating:0))
                if simd_length(outside) > radius { high = mid } else { low = mid }
            }
            let ripple = 0.13 + 0.12 * sin(angle*11) * cos(angle*7)
            return direction * (low + ripple)
        }
        var distances = [Double](repeating:0,count:count+1)
        for i in 1...count { distances[i] = distances[i-1] + simd_distance(outline[i%count],outline[i-1]) }
        let heights: [Double] = [-0.11,-0.63,-2.2,-Double(layout.rockDepth)*0.60,-Double(layout.rockDepth)*0.88,-Double(layout.rockDepth)-0.9]
        let scales: [Double] = [1,1.008,0.97,0.83,0.38,0.015]
        let rockMaterial = material(NSColor(calibratedRed:0.71,green:0.76,blue:0.76,alpha:1), image:rock)
        let turfMaterial = material(NSColor(calibratedRed:0.42,green:0.63,blue:0.36,alpha:1), image:grass)
        let mossMaterial = material(NSColor(calibratedRed:0.28,green:0.43,blue:0.30,alpha:1), image:rock)
        for ring in 0..<(heights.count-1) {
            var vertices: [SCNVector3] = [], uv: [CGPoint] = [], indices: [Int32] = []
            func point(_ i:Int,_ level:Int) -> SCNVector3 {
                let a=Double(i) * Double.pi * 2 / Double(count)
                let irregular = level <= 1 ? 1 : 1 + 0.045*sin(a*9+Double(level)) + 0.025*cos(a*17)
                let p=outline[i%count]*scales[level]*irregular
                let y=heights[level] + (level <= 1 ? 0 : 0.35*sin(a*7+Double(level)))
                return SCNVector3(p.x,y,p.y)
            }
            for i in 0...count {
                for level in [ring,ring+1] {
                    vertices.append(point(i,level))
                    uv.append(CGPoint(x:distances[i]/6,y:-heights[level]/5))
                }
                if i<count { let k=Int32(i*2); indices += [k,k+2,k+1,k+1,k+2,k+3] }
            }
            let geometry=SCNGeometry(sources:[SCNGeometrySource(vertices:vertices),SCNGeometrySource(textureCoordinates:uv)],
                                     elements:[SCNGeometryElement(indices:indices,primitiveType:.triangles)])
            geometry.materials=[ring == 0 ? mossMaterial : rockMaterial]
            root.addChildNode(SCNNode(geometry:geometry))
        }
        // A continuous grass lip underneath the existing per-cell terrain.
        var top=[SCNVector3(0,-0.11,0)]
        var topUV=[CGPoint(x:layout.width/12,y:layout.depth/12)]
        for p in outline { top.append(SCNVector3(p.x,-0.11,p.y)); topUV.append(CGPoint(x:(p.x+Double(layout.width/2))/6,y:(p.y+Double(layout.depth/2))/6)) }
        var topIndices:[Int32]=[]
        for i in 0..<count { topIndices += [0,Int32((i+1)%count+1),Int32(i+1)] }
        let cap=SCNGeometry(sources:[SCNGeometrySource(vertices:top),SCNGeometrySource(textureCoordinates:topUV)],elements:[SCNGeometryElement(indices:topIndices,primitiveType:.triangles)])
        cap.materials=[turfMaterial];root.addChildNode(SCNNode(geometry:cap))

        // Cliff roots and small suspended fragments scale with the island perimeter.
        let detailCount = min(36, max(12,Int((layout.width+layout.depth)/2)))
        for i in 0..<detailCount {
            let index=i*count/detailCount
            let p=outline[index]
            let shard=SCNCone(topRadius:0.48+CGFloat(i%3)*0.15,bottomRadius:0.06,height:1.6+CGFloat(i%4)*0.42)
            shard.radialSegmentCount=7;shard.materials=[rockMaterial]
            let node=SCNNode(geometry:shard)
            node.position=SCNVector3(p.x*0.91,-2.1-Double(i%3)*0.45,p.y*0.91)
            node.eulerAngles.z=CGFloat(sin(Double(i))*0.13);root.addChildNode(node)
            if i%3 == 0 {
                for j in 0..<5 {
                    let leaf=SCNSphere(radius:0.14+CGFloat(j%2)*0.04);leaf.segmentCount=6
                    leaf.materials=[mossMaterial]
                    let vine=SCNNode(geometry:leaf)
                    vine.scale=SCNVector3(1.1,1.7,0.6)
                    vine.position=SCNVector3(p.x*(1-Double(j)*0.01),-0.35-Double(j)*0.31,p.y*(1-Double(j)*0.01))
                    root.addChildNode(vine)
                }
            }
        }
        // Waterfalls are anchored outside playable cells; expansion moves them to the new edge.
        for index in [count/8, count*5/8] {
            let edge=outline[index]
            let drop=Double(layout.rockDepth)*0.82
            let width=0.48
            var v:[SCNVector3]=[],t:[CGPoint]=[],ids:[Int32]=[]
            let tangent=simd_normalize(SIMD2(-edge.y,edge.x))
            for j in 0...12 {
                let f=Double(j)/12
                let center=edge*(1+f*0.075)
                for side in [-1.0,1.0] {
                    let p=center+tangent*width*side*(1-f*0.4)
                    v.append(SCNVector3(p.x,-0.16-f*drop,p.y));t.append(CGPoint(x:(side+1)/2,y:f))
                }
                if j<12 {let k=Int32(j*2);ids += [k,k+1,k+2,k+1,k+3,k+2]}
            }
            let mesh=SCNGeometry(sources:[SCNGeometrySource(vertices:v),SCNGeometrySource(textureCoordinates:t)],elements:[SCNGeometryElement(indices:ids,primitiveType:.triangles)])
            let water=material(NSColor(calibratedRed:0.61,green:0.86,blue:0.91,alpha:0.68),image:nil)
            water.emission.contents=NSColor(calibratedRed:0.05,green:0.14,blue:0.15,alpha:1)
            water.diffuse.contents=waterTexture
            water.lightingModel = .constant
            water.writesToDepthBuffer=false
            mesh.materials=[water];root.addChildNode(SCNNode(geometry:mesh))
        }
        return root
    }

    private static func material(_ color:NSColor,image:NSImage?) -> SCNMaterial {
        let m=SCNMaterial();m.lightingModel = .lambert;m.isDoubleSided=true
        m.diffuse.contents=image ?? color
        if image != nil {m.multiply.contents=color}
        m.diffuse.wrapS = .repeat;m.diffuse.wrapT = .repeat
        m.roughness.contents=0.94
        return m
    }

    private static let waterTexture: NSImage = {
        let image=NSImage(size:NSSize(width:128,height:512));image.lockFocus()
        for x in 0..<128 {
            let wave=0.6+0.4*sin(Double(x)*0.73)
            for y in stride(from:0,to:512,by:8) {
                let fade=Double(y)/512
                NSColor(calibratedRed:0.68,green:0.90,blue:0.96,alpha:wave*fade*0.8).setFill()
                NSRect(x:x,y:y,width:1,height:8).fill()
            }
        }
        image.unlockFocus();return image
    }()
}

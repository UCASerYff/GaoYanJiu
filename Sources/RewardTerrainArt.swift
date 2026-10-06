import AppKit
import SceneKit
import simd

/// One authored landscape is used both on the board and in wish/inventory cards.
enum RewardTerrainArt {
    private static let models = NSCache<NSString, SCNNode>()
    private static let pictures = NSCache<NSString, NSImage>()
    static func model(_ terrain: RewardTerrainDefinition, joined: Int = 0) -> SCNNode {
        models.countLimit = 128
        let key = "\(terrain.id):\(joined)" as NSString
        if let n = models.object(forKey: key) { return n.clone() }
        let n = Landscape(terrain, joined: joined).build()
        models.setObject(n, forKey: key)
        return n.clone()
    }
    static func thumbnail(_ terrain: RewardTerrainDefinition) -> NSImage {
        pictures.countLimit = 80
        if let image = pictures.object(forKey: terrain.id as NSString) { return image }
        let image = render(model(terrain), size: NSSize(width: 440, height: 330))
        pictures.setObject(image, forKey: terrain.id as NSString)
        return image
    }
    static func render(_ model: SCNNode, size: NSSize) -> NSImage {
        let scene = SCNScene(); scene.background.contents = NSColor(calibratedRed:0.88,green:0.92,blue:0.91,alpha:1)
        scene.rootNode.addChildNode(model)
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light!.type = .ambient; ambient.light!.intensity = 450
        scene.rootNode.addChildNode(ambient)
        let sun = SCNNode(); sun.light = SCNLight(); sun.light!.type = .directional; sun.light!.intensity = 1000
        sun.eulerAngles = SCNVector3(-0.9,-0.7,0); scene.rootNode.addChildNode(sun)
        let camera = SCNNode(); camera.camera = SCNCamera(); camera.camera!.usesOrthographicProjection = true
        camera.camera!.orthographicScale = 3.15; camera.position = SCNVector3(5,4.7,6)
        camera.look(at:SCNVector3(0,0.5,0)); scene.rootNode.addChildNode(camera)
        let renderer = SCNRenderer(device:nil,options:nil); renderer.scene = scene; renderer.pointOfView = camera
        return renderer.snapshot(atTime:0,with:size,antialiasingMode:.multisampling4X)
    }
    static func joinedMask(_ terrain: RewardTerrainDefinition, row: Int, column: Int, state: RewardCityState) -> Int {
        var mask = 0
        for (i,p) in [(-1,0),(1,0),(0,-1),(0,1)].enumerated() {
            let key = RewardCityGrid.id(row:row+p.0,column:column+p.1)
            if let id = state.plotTerrains[key], RewardCatalog.terrain(id:id)?.kind == terrain.kind { mask |= 1 << i }
        }
        return mask
    }
}

private final class Landscape {
    let t: RewardTerrainDefinition
    let joined: Int
    let root = SCNNode()
    var seed: Double { Double(t.variant) * 0.73 }
    init(_ terrain: RewardTerrainDefinition, joined: Int) { t = terrain; self.joined = joined }
    func noise(_ x: Double,_ z: Double) -> Double { (sin(x*6.2+z*4.1+seed)+sin(x*13.1-z*9.2+seed)*0.34)*0.035 }
    func edge(_ x: Double,_ z: Double) -> Double {
        let distances = [z+1.5,1.5-z,x+1.5,1.5-x]
        return (0..<4).filter { joined & (1 << $0) == 0 }.map { distances[$0] }.min() ?? 4
    }
    func mound(_ x: Double,_ z: Double,_ cx: Double,_ cz: Double,_ width: Double) -> Double {
        exp(-((x-cx)*(x-cx)+(z-cz)*(z-cz))/width)
    }
    func lakeDistance(_ x: Double,_ z: Double) -> Double {
        let distances = [z+1.5,1.5-z,x+1.5,1.5-x]
        let shores = (0..<4).filter { joined & (1 << $0) == 0 }.map { distances[$0] }
        guard !shores.isEmpty else { return 4 }
        // A smooth shoreline rounds the lake corners. Interior undulations
        // taper to zero at tile boundaries so neighboring variants still join.
        let smooth = -0.42*log(shores.reduce(0) { $0+exp(-$1/0.42) })
        let interior = max(0,min(1,min(1.5-abs(x),1.5-abs(z))*3))
        return smooth + interior*(0.10*sin(x*3+z*2+seed)+0.04*cos(z*6-x))
    }
    func height(_ x: Double,_ z: Double) -> Double {
        let d = edge(x,z), fade = min(1,max(0,d/0.38))
        let n = noise(x,z)
        switch t.kind {
        case .lake:
            let shore = lakeDistance(x,z)
            return shore < 0.18 ? 0.135+max(0,noise(x,z))*0.4 : 0.112
        case .forest: return 0.135 + fade*(0.10*mound(x,z,-0.35,0.3,1.2)+n*0.5)
        case .desert:
            let dune = pow(max(0,0.5+0.5*sin(x*3+sin(z*1.9+seed))),2)*0.35
            return 0.135+fade*(dune+0.06*sin(z*3+x+seed)+0.075)
        case .snowMountain:
            let ridges = max(1.65*mound(x,z,0.23+sin(seed)*0.15,-0.25,0.20),1.15*mound(x,z,-0.58,0.20,0.18),0.8*mound(x,z,0.67,0.58,0.13))
            return 0.135+fade*(ridges+max(0,n)*2.4)
        case .wetland:
            let channel = abs(x-0.48*sin(z*2.2+seed))
            return channel < 0.30 ? 0.112 : 0.145+fade*(0.04+n*0.5)
        case .volcanic:
            let r = sqrt(x*x+z*z), rim = 1.25*exp(-pow((r-0.36)/0.48,2))
            return 0.135+fade*max(0.06,rim+noise(x*1.2,z*1.2)*2)
        case .flowerMeadow: return 0.135+fade*(0.16*mound(x,z,0,0,1.4)+n*0.5)
        case .crystalField: return 0.135+fade*(0.16*mound(x,z,0.2,0.1,1)+abs(n)*1.3)
        }
    }
    func color(_ x: Double,_ z: Double,_ y: Double) -> Int {
        let d = edge(x,z), n = noise(x,z)
        if d < 0.10 { return 0x66865a }
        switch t.kind {
        case .lake:
            let shore = lakeDistance(x,z)
            return y > 0.13 ? (shore < 0.02 ? 0x93a57a:0xd8ca9c) : shore < 0.34 ? 0x54b0ac : shore < 0.58 ? 0x328f9c : 0x246880
        case .forest: return n > 0.01 ? 0x698254 : n < -0.02 ? 0x3e6247 : 0x52704c
        case .desert: return y > 0.37 ? 0xedcf96 : n > 0 ? 0xd9b77e : 0xc6a06c
        case .snowMountain: return y > 0.82+n*2 ? 0xf1f3ed : y > 0.50 ? 0x8a9698 : y > 0.27 ? 0x6c7e80 : 0x8b9b8b
        case .wetland: return y < 0.13 ? 0x4f9691 : n > 0 ? 0x7d9160 : 0x5d7952
        case .volcanic:
            let r = sqrt(x*x+z*z)
            if r < 0.24 { return 0xf18c32 }
            if abs(x-0.17*sin(z*4)) < 0.05 && z > 0 { return 0xd46730 }
            return n > 0 ? 0x555653:0x41494a
        case .flowerMeadow: return n > 0 ? 0x829960:0x67864d
        case .crystalField: return n > 0 ? 0x7f8296:0x666f84
        }
    }
    @discardableResult func add(_ g: SCNGeometry,_ x: Double,_ y: Double,_ z: Double,_ c: Int) -> SCNNode {
        let n = SCNNode(geometry:g); n.position = SCNVector3(x,y,z)
        g.materials = [RewardArchitecture.material(c)]; root.addChildNode(n); return n
    }
    func rock(_ x: Double,_ z: Double,_ size: Double,_ c: Int) {
        let g = SCNSphere(radius:size); g.segmentCount = 6
        let n = add(g,x,height(x,z)+size*0.30,z,c); n.scale = SCNVector3(1,0.55,0.8)
    }
    func stem(_ x: Double,_ y: Double,_ z: Double,_ h: Double,_ r: Double,_ c: Int) {
        let g = SCNCylinder(radius:r,height:h); g.radialSegmentCount = 6; add(g,x,y+h/2,z,c)
    }
    func tree(_ x: Double,_ z: Double,_ h: Double, snowy: Bool = false) {
        let base = height(x,z)
        stem(x,base,z,h*0.6,0.036,0x735a3c)
        for i in 0..<3 {
            let radius = h*(0.34-Double(i)*0.06)
            let g = SCNCone(topRadius:0.018,bottomRadius:radius,height:h*0.48); g.radialSegmentCount = 7
            add(g,x,base+h*(0.46+Double(i)*0.19),z,[0x42664c,0x4f7852,0x64875c][i])
            if snowy { let cap = SCNCone(topRadius:0,bottomRadius:radius*0.72,height:h*0.34); cap.radialSegmentCount = 7; add(cap,x,base+h*(0.52+Double(i)*0.19),z,0xe7eee4) }
        }
    }
    func mesh() {
        var vertices: [SCNVector3] = [], normals: [SCNVector3] = []
        var groups: [Int:[Int32]] = [:]
        let steps = 30
        for row in 0..<steps { for col in 0..<steps {
            let x = -1.5+Double(col)*3/Double(steps), z = -1.5+Double(row)*3/Double(steps), step = 3/Double(steps)
            for coords in [[(x,z),(x,z+step),(x+step,z)],[(x+step,z),(x,z+step),(x+step,z+step)]] {
                let p = coords.map { SIMD3<Float>(Float($0.0),Float(height($0.0,$0.1)),Float($0.1)) }
                let normal = simd_normalize(simd_cross(p[1]-p[0],p[2]-p[0]))
                let center = (p[0]+p[1]+p[2])/3
                let c = color(Double(center.x),Double(center.z),Double(center.y))
                let start = Int32(vertices.count)
                groups[c,default:[]] += [start,start+1,start+2]
                vertices += p.map { SCNVector3($0.x,$0.y,$0.z) }
                normals += Array(repeating:SCNVector3(normal.x,normal.y,normal.z),count:3)
            }
        } }
        let colors = groups.keys.sorted()
        let geometry = SCNGeometry(sources:[SCNGeometrySource(vertices:vertices),SCNGeometrySource(normals:normals)],elements:colors.map { SCNGeometryElement(indices:groups[$0]!,primitiveType:.triangles) })
        geometry.materials = colors.map { c in
            let m = RewardArchitecture.material(c).copy() as! SCNMaterial
            if [0x54b0ac,0x328f9c,0x246880,0x4f9691].contains(c) { m.roughness.contents = 0.20; m.metalness.contents = 0.12 }
            return m
        }
        root.addChildNode(SCNNode(geometry:geometry))
        let base = SCNBox(width:3,height:0.10,length:3,chamferRadius:0)
        add(base,0,0.06,0,0x655f50)
    }
    func build() -> SCNNode {
        mesh()
        switch t.kind {
        case .lake:
            for i in 0..<5 { let x = sin(Double(i)*2.5+seed)*0.85,z = cos(Double(i)*1.7+seed)*0.80
                let g = SCNBox(width:0.22+Double(i%2)*0.10,height:0.004,length:0.014,chamferRadius:0.006)
                let n = add(g,x,0.117,z,0x9acccb); n.eulerAngles.y = 0.3
            }
            if joined == 0 {
                for i in 0..<7 {
                    let x = -1.03+Double(i%3)*0.075,z = -1.07+Double(i/3)*0.075
                    rock(x,z,0.055+Double(i%2)*0.03,0xa2a48b)
                    stem(x+0.055,height(x,z),z,0.18+Double(i%3)*0.03,0.008,0x698c54)
                }
            }
        case .forest:
            for i in 0..<13 {
                let x = sin(Double(i)*2.399+seed)*sqrt(Double(i+1)/14)*1.12
                let z = cos(Double(i)*2.399+seed)*sqrt(Double(i+1)/14)*1.12
                tree(x,z,0.58+Double((i+t.variant)%4)*0.13)
            }
            for i in 0..<8 { rock(sin(Double(i)*3.1)*1.22,cos(Double(i)*2.3)*1.12,0.07,0x89977b) }
        case .desert:
            for i in 0..<5 { rock(sin(Double(i)*2+seed)*1.03,cos(Double(i)*3.1+seed)*0.96,0.09,0x997c54) }
            let x = -0.83,z = 0.77,y = height(x,z)
            stem(x,y,z,0.42,0.043,0x728258); stem(x+0.12,y+0.14,z,0.20,0.025,0x728258)
            let arm = add(SCNBox(width:0.14,height:0.035,length:0.035,chamferRadius:0.014),x+0.05,y+0.18,z,0x728258); arm.eulerAngles.z = 0.1
        case .snowMountain:
            for i in 0..<5 { let x = -1.10+Double(i)*0.48,z = 1.01; tree(x,z,0.34+Double(i%2)*0.12,snowy:true) }
            for i in 0..<6 { rock(sin(Double(i)*2.4)*1.10,cos(Double(i)*2.4)*1.05,0.08,0xaeb8b5) }
        case .wetland:
            for i in 0..<24 {
                let z = -1.12+Double(i%12)*0.19,x = 0.48*sin(z*2.2+seed)+(i<12 ? -0.40:0.40)
                let h = 0.25+Double(i%4)*0.035,y = height(x,z)
                stem(x,y,z,h,0.008,0x9a9b60); stem(x,y+h*0.82,z,0.08,0.019,0x7d6648)
            }
            for i in 0..<5 { let z = -0.85+Double(i)*0.38,x = 0.48*sin(z*2.2+seed); let n = add(SCNCylinder(radius:0.067,height:0.008),x,0.119,z,0x9eae76); n.scale.z = 0.75 }
        case .volcanic:
            for i in 0..<9 { let angle = Double(i)*0.7; rock(sin(angle)*1.13,cos(angle)*1.13,0.10,0x666361) }
        case .flowerMeadow:
            for i in 0..<64 {
                let x = sin(Double(i)*2.399+seed)*sqrt(Double(i+1)/65)*1.25,z = cos(Double(i)*2.399+seed)*sqrt(Double(i+1)/65)*1.25,y = height(x,z)
                stem(x,y,z,0.09,0.006,0x54763e)
                let colors = [0xd8a4b8,0xe9d595,0xb0a0c6]
                for p in 0..<4 { let angle = Double(p)*Double.pi/2; let g = SCNSphere(radius:0.025); g.segmentCount = 6; let n = add(g,x+cos(angle)*0.022,y+0.11,z+sin(angle)*0.022,colors[(i+t.variant)%3]); n.scale.y = 0.45 }
            }
        case .crystalField:
            for i in 0..<12 {
                let x = sin(Double(i)*2.399+seed)*sqrt(Double(i+1)/13)*1.06,z = cos(Double(i)*2.399+seed)*sqrt(Double(i+1)/13)*1.06
                let h = 0.24+Double((i+t.variant)%5)*0.13,r = 0.07+Double(i%3)*0.018,y = height(x,z)
                let g = SCNCylinder(radius:r,height:h); g.radialSegmentCount = 6
                add(g,x,y+h/2,z,[0x91b5c6,0xaaa1c6,0x91c4bd][i%3])
                let tip = SCNCone(topRadius:0,bottomRadius:r,height:r*1.7); tip.radialSegmentCount = 6
                add(tip,x,y+h+r*0.85,z,[0xbadbe2,0xd1c3de,0xb9dfd4][i%3])
            }
        }
        return root
    }
}

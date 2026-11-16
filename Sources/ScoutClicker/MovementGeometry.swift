import Foundation
import CoreGraphics

public struct MovementDisplay: Equatable, Sendable {
    public var identity: String
    public var bounds: CGRect
    public init(identity: String, bounds: CGRect) { self.identity = identity; self.bounds = bounds }
}
public struct MovementBox: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var rect: CGRect // Display-local, top-left origin, logical screen points (not pixels).
    public var blocked: Bool
    public var secondaryClick: Bool
    public init(rect: CGRect, blocked: Bool, secondaryClick: Bool = false, id: UUID = UUID()) {
        self.id = id; self.rect = rect; self.blocked = blocked; self.secondaryClick = secondaryClick
    }
    private enum CodingKeys: String, CodingKey { case id, rect, blocked, secondaryClick }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        rect = try c.decode(CGRect.self, forKey: .rect)
        blocked = try c.decode(Bool.self, forKey: .blocked)
        secondaryClick = try c.decodeIfPresent(Bool.self, forKey: .secondaryClick) ?? false
    }
}
public struct MovementRegionProfile: Codable, Equatable, Sendable {
    public var displayIdentity: String
    public var referenceSize: CGSize
    public var boxes: [MovementBox]
    public init(displayIdentity: String, referenceSize: CGSize, boxes: [MovementBox]) {
        self.displayIdentity = displayIdentity; self.referenceSize = referenceSize; self.boxes = boxes
    }
    private func matches(_ display: MovementDisplay) -> Bool {
        display.identity == displayIdentity && display.bounds.size == referenceSize && boxes.count <= 32 &&
              boxes.filter(\.secondaryClick).count <= 1 &&
              boxes.allSatisfy({ box in
                  let r = box.rect
                  return [r.minX,r.minY,r.width,r.height].allSatisfy(\.isFinite) && r.width > 0 && r.height > 0 &&
                      CGRect(origin: .zero, size: referenceSize).contains(r) && !(box.blocked && box.secondaryClick)
              })
    }
    public func domain(for display: MovementDisplay) -> MovementDomain? {
        guard matches(display) else { return nil }
        return MovementDomain(bounds: display.bounds, allowed: boxes.filter { !$0.blocked && !$0.secondaryClick }.map { $0.rect.offsetBy(dx: display.bounds.minX, dy: display.bounds.minY) }, blocked: boxes.filter(\.blocked).map { $0.rect.offsetBy(dx: display.bounds.minX, dy: display.bounds.minY) })
    }
    public func secondaryClickArea(for display: MovementDisplay) -> CGRect? {
        guard matches(display), let box = boxes.first(where: \.secondaryClick) else { return nil }
        return box.rect.offsetBy(dx: display.bounds.minX, dy: display.bounds.minY)
    }
    /// Purple selects the destination, while red boxes constrain the whole trip.
    /// Green boxes retain their existing meaning for large random movement only.
    public func secondaryDomain(for display: MovementDisplay) -> MovementDomain? {
        guard let area = secondaryClickArea(for: display) else { return nil }
        let domain = MovementDomain(bounds: display.bounds, blocked: boxes.filter(\.blocked).map { $0.rect.offsetBy(dx: display.bounds.minX, dy: display.bounds.minY) })
        let xs = Array(Set([area.minX, area.maxX] + domain.blocked.flatMap { [$0.minX, $0.maxX] }.filter { $0 > area.minX && $0 < area.maxX })).sorted()
        let ys = Array(Set([area.minY, area.maxY] + domain.blocked.flatMap { [$0.minY, $0.maxY] }.filter { $0 > area.minY && $0 < area.maxY })).sorted()
        for x in 1..<xs.count { for y in 1..<ys.count {
            if domain.contains(CGPoint(x: (xs[x-1]+xs[x])/2, y: (ys[y-1]+ys[y])/2)) { return domain }
        } }
        return nil
    }
}

public func movementDistance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x-b.x, a.y-b.y) }
private func mix(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint { CGPoint(x: a.x+(b.x-a.x)*t, y: a.y+(b.y-a.y)*t) }
private func closedContains(_ r: CGRect, _ p: CGPoint) -> Bool { p.x >= r.minX && p.x <= r.maxX && p.y >= r.minY && p.y <= r.maxY }

/// Exact rectangle-boundary partitioning for lines, and conservative convex-hull
/// certification for the whole cubic. Sampling is used only for pacing, never for safety.
public struct MovementDomain: Sendable {
    public var bounds: CGRect
    public var allowed: [CGRect]
    public var blocked: [CGRect]
    public init(bounds: CGRect, allowed: [CGRect] = [], blocked: [CGRect] = []) { self.bounds = bounds; self.allowed = allowed; self.blocked = blocked }
    public func contains(_ p: CGPoint) -> Bool {
        p.x.isFinite && p.y.isFinite && closedContains(bounds, p) &&
        (allowed.isEmpty || allowed.contains { closedContains($0,p) }) && !blocked.contains { closedContains($0.insetBy(dx:-0.000000001,dy:-0.000000001),p) }
    }
    public func permitsSegment(_ a: CGPoint, _ b: CGPoint) -> Bool {
        guard contains(a), contains(b) else { return false }
        for rect in blocked {
            let r=rect.insetBy(dx:-0.000000001,dy:-0.000000001)
            var lo=0.0,hi=1.0,possible=true
            for (origin,delta,minValue,maxValue) in [(a.x,b.x-a.x,r.minX,r.maxX),(a.y,b.y-a.y,r.minY,r.maxY)] {
                if delta == 0 { if origin<minValue || origin>maxValue { possible=false } }
                else { let t0=(minValue-origin)/delta,t1=(maxValue-origin)/delta;lo=max(lo,min(t0,t1));hi=min(hi,max(t0,t1)) }
            }
            if possible && lo <= hi { return false }
        }
        var cuts = [0.0,1.0]
        for r in [bounds] + allowed + blocked {
            if a.x != b.x { for x in [r.minX,r.maxX] { let t=(x-a.x)/(b.x-a.x); if t > 0 && t < 1 { cuts.append(t) } } }
            if a.y != b.y { for y in [r.minY,r.maxY] { let t=(y-a.y)/(b.y-a.y); if t > 0 && t < 1 { cuts.append(t) } } }
        }
        cuts.sort()
        // Boundaries matter: even a tangent touch of a blocked box is forbidden.
        for t in cuts { if !contains(mix(a,b,t)) { return false } }
        for i in 1..<cuts.count { if !contains(mix(a,b,(cuts[i-1]+cuts[i])/2)) { return false } }
        return true
    }
    private func covers(_ rect: CGRect) -> Bool {
        guard closedContains(bounds, rect.origin), closedContains(bounds, CGPoint(x:rect.maxX,y:rect.maxY)) else { return false }
        if blocked.contains(where: { $0.minX <= rect.maxX && $0.maxX >= rect.minX && $0.minY <= rect.maxY && $0.maxY >= rect.minY }) { return false }
        guard !allowed.isEmpty else { return true }
        let xs = ([rect.minX,rect.maxX] + allowed.flatMap { [$0.minX,$0.maxX] }.filter { $0 > rect.minX && $0 < rect.maxX }).sorted()
        let ys = ([rect.minY,rect.maxY] + allowed.flatMap { [$0.minY,$0.maxY] }.filter { $0 > rect.minY && $0 < rect.maxY }).sorted()
        for x in 1..<xs.count { for y in 1..<ys.count {
            if !allowed.contains(where: { closedContains($0,CGPoint(x:(xs[x-1]+xs[x])/2,y:(ys[y-1]+ys[y])/2)) }) { return false }
        } }
        return true
    }
    public func permitsCurve(_ curve: MovementCurve) -> Bool {
        let deadline=ProcessInfo.processInfo.systemUptime+0.015
        var budget = 8192
        func certify(_ c: MovementCurve, _ depth: Int) -> Bool {
            budget -= 1
            guard budget >= 0, ProcessInfo.processInfo.systemUptime <= deadline, contains(c.a), contains(c.d) else { return false }
            let points=[c.a,c.b,c.c,c.d], xs=points.map(\.x), ys=points.map(\.y)
            let hull=CGRect(x:xs.min()!,y:ys.min()!,width:xs.max()!-xs.min()!,height:ys.max()!-ys.min()!)
            if covers(hull) { return true }
            guard depth < 18 else { return false } // Fail closed for uncertifiable/tangent curves.
            let halves=c.split()
            return certify(halves.0,depth+1) && certify(halves.1,depth+1)
        }
        return certify(curve,0)
    }
    /// Cell decomposition at every rectangle edge. Thin obstacles cannot disappear
    /// between grid samples; adjacent cells are connected only by certified segments.
    public func route(from start: CGPoint, to end: CGPoint) -> [CGPoint]? {
        let deadline=ProcessInfo.processInfo.systemUptime+0.02
        guard contains(start), contains(end), allowed.count + blocked.count <= 32 else { return nil }
        if permitsSegment(start,end) { return [start,end] }
        let rects=[bounds]+allowed+blocked
        let xs=Array(Set(rects.flatMap { [$0.minX,$0.maxX] }.filter { $0 >= bounds.minX && $0 <= bounds.maxX })).sorted()
        let ys=Array(Set(rects.flatMap { [$0.minY,$0.maxY] }.filter { $0 >= bounds.minY && $0 <= bounds.maxY })).sorted()
        guard xs.count > 1, ys.count > 1, xs.count * ys.count <= 5000 else { return nil }
        let nx=xs.count-1, ny=ys.count-1
        var nodes=[Int:CGPoint](), starts=[Int](), ends=Set<Int>()
        for j in 0..<ny {
            guard ProcessInfo.processInfo.systemUptime <= deadline else { return nil }
            for i in 0..<nx {
            let id=j*nx+i, p=CGPoint(x:(xs[i]+xs[i+1])/2,y:(ys[j]+ys[j+1])/2)
            guard contains(p) else { continue }; nodes[id]=p
            let cell=CGRect(x:xs[i],y:ys[j],width:xs[i+1]-xs[i],height:ys[j+1]-ys[j])
            if closedContains(cell,start) && permitsSegment(start,p) { starts.append(id) }
            if closedContains(cell,end) && permitsSegment(p,end) { ends.insert(id) }
        } }
        var queue=starts, parent=Dictionary(uniqueKeysWithValues:starts.map { ($0,-1) }), cursor=0, found:Int?
        while cursor < queue.count {
            guard ProcessInfo.processInfo.systemUptime <= deadline else { return nil }
            let id=queue[cursor];cursor += 1
            if ends.contains(id) { found=id;break }
            let i=id%nx,j=id/nx
            for (x,y) in [(i-1,j),(i+1,j),(i,j-1),(i,j+1)] where x>=0 && x<nx && y>=0 && y<ny {
                let next=y*nx+x
                if parent[next] == nil, let p=nodes[next], permitsSegment(nodes[id]!,p) { parent[next]=id;queue.append(next) }
            }
        }
        guard var id=found else { return nil }
        var path=[end]
        while id >= 0 { path.append(nodes[id]!);id=parent[id]! }
        path.append(start);path.reverse()
        var simple=[start], index=0
        while index < path.count-1 {
            var next=path.count-1
            while next > index+1 && !permitsSegment(path[index],path[next]) { next -= 1 }
            simple.append(path[next]);index=next
        }
        return simple
    }
}

public struct MovementCurve: Sendable {
    public var a,b,c,d: CGPoint
    public init(_ a: CGPoint,_ b: CGPoint,_ c: CGPoint,_ d: CGPoint) { self.a=a;self.b=b;self.c=c;self.d=d }
    public func point(_ t: Double) -> CGPoint {
        let ab=mix(a,b,t),bc=mix(b,c,t),cd=mix(c,d,t)
        return mix(mix(ab,bc,t),mix(bc,cd,t),t)
    }
    public func split() -> (Self,Self) {
        let ab=mix(a,b,0.5),bc=mix(b,c,0.5),cd=mix(c,d,0.5),m=point(0.5)
        return (Self(a,ab,mix(ab,bc,0.5),m),Self(m,mix(bc,cd,0.5),cd,d))
    }
}
public struct MovementPath: Sendable {
    public var curves: [MovementCurve]
    public var points: [CGPoint]
}
public enum CurvedMovement {
    /// Shared tangents at intermediate knots and arc-length pacing avoid corner
    /// jerks. Outward/return calls draw separate random control offsets.
    public static func plan(from start: CGPoint, to end: CGPoint, domain: MovementDomain, random: (ClosedRange<Double>)->Double) -> MovementPath? {
        let deadline=ProcessInfo.processInfo.systemUptime+0.04
        guard let knots=domain.route(from:start,to:end), movementDistance(start,end)>0.0001 else { return nil }
        let sign = random(0...1) < 0.5 ? -1.0 : 1.0
        let amount=random(0.09...0.22)
        for attempt in 0..<12 {
            guard ProcessInfo.processInfo.systemUptime <= deadline else { return nil }
            let scale=pow(0.5,Double(attempt))
            var curves=[MovementCurve]()
            for i in 0..<knots.count-1 {
                guard ProcessInfo.processInfo.systemUptime <= deadline else { return nil }
                let a=knots[i],d=knots[i+1],distance=movementDistance(a,d)
                var b:CGPoint,c:CGPoint
                if knots.count == 2 {
                    let offset=distance*amount*scale*sign, nx = -(d.y-a.y)/distance, ny=(d.x-a.x)/distance
                    let p=mix(a,d,0.30),q=mix(a,d,0.70)
                    b=CGPoint(x:p.x+nx*offset,y:p.y+ny*offset);c=CGPoint(x:q.x+nx*offset*0.75,y:q.y+ny*offset*0.75)
                } else {
                    func tangent(_ k: Int) -> CGPoint {
                        let before=knots[max(0,k-1)],after=knots[min(knots.count-1,k+1)]
                        let length=max(0.0001,movementDistance(before,after))
                        return CGPoint(x:(after.x-before.x)/length,y:(after.y-before.y)/length)
                    }
                    let t=tangent(i),u=tangent(i+1)
                    let left=min(distance,i>0 ? movementDistance(knots[i-1],a) : distance)*amount*scale
                    let right=min(distance,i+2<knots.count ? movementDistance(d,knots[i+2]) : distance)*amount*scale
                    b=CGPoint(x:a.x+t.x*left,y:a.y+t.y*left);c=CGPoint(x:d.x-u.x*right,y:d.y-u.y*right)
                }
                curves.append(MovementCurve(a,b,c,d))
            }
            guard curves.allSatisfy({ ProcessInfo.processInfo.systemUptime <= deadline && domain.permitsCurve($0) }) else { continue }
            // Arc-length lookup only sets speed. Full curves are already certified.
            var fine=[start]
            for c in curves { for i in 1...100 { fine.append(c.point(Double(i)/100)) } }
            var lengths=[0.0]
            for i in 1..<fine.count { lengths.append(lengths.last!+movementDistance(fine[i-1],fine[i])) }
            let length=lengths.last!, steps=max(12,min(160,Int(ceil(length/6))+12))
            var points=[CGPoint](), index=1
            for i in 1...steps {
                let t=Double(i)/Double(steps), wanted=length*t*t*(3-2*t)
                while index<lengths.count-1 && lengths[index]<wanted { index += 1 }
                let span=lengths[index]-lengths[index-1]
                points.append(i == steps ? end : mix(fine[index-1],fine[index],span > 0 ? (wanted-lengths[index-1])/span : 0))
            }
            var previous=start
            guard points.allSatisfy({ p in defer { previous=p };return domain.permitsSegment(previous,p) }) else { continue }
            return MovementPath(curves:curves,points:points)
        }
        return nil
    }
}
